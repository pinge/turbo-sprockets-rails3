begin
  require 'sprockets/static_compiler'
rescue LoadError
end

# Sprockets::StaticCompiler was only introduced in Rails 3.2.x
if defined?(Sprockets::StaticCompiler)
  module Sprockets
    StaticCompiler.class_eval do

      def initialize(env, target, paths, options = {})
        @env = env
        @target = target
        @paths = paths
        @digest = options.fetch(:digest, true)
        @manifest = options.fetch(:manifest, true)
        @manifest_path = options.delete(:manifest_path) || target
        @zip_files = options.delete(:zip_files) || /\.(?:css|html|js|svg|txt|xml)$/

        @current_source_digests = options.fetch(:source_digests, {})
        @current_digest_files   = options.fetch(:digest_files,   {})

        @digest_files   = {}
        @source_digests = {}
      end

      def processor_count
        begin
          @@cpu_cores ||=
              case RbConfig::CONFIG['host_os']
                when /darwin9/
                  `hwprefs cpu_count`.to_i
                when /darwin/
                  ((`which hwprefs` != '') ? `hwprefs thread_count` : `sysctl -n hw.ncpu`).to_i
                when /linux/
                  `cat /proc/cpuinfo | grep processor | wc -l`.to_i
                when /freebsd/
                  `sysctl -n hw.ncpu`.to_i
                when /mswin|mingw/
                  require 'win32ole'
                  wmi = WIN32OLE.connect("winmgmts://")
                  cpu = wmi.ExecQuery("select NumberOfCores from Win32_Processor") # TODO count hyper-threaded in this
                  cpu.to_enum.first.NumberOfCores
                else
                  1
              end
        rescue Exception => e
          @@cpu_cores = 1
        end
      end

      def compile
        start_time = Time.now.to_f
        logical_paths = []
        env.each_logical_path do |logical_path|
          if File.basename(logical_path)[/[^\.]+/, 0] == 'index'
            logical_path.sub!(/\/index\./, '.')
          end
          next unless compile_path?(logical_path)
          # Fetch asset without any processing or compression,
          # to calculate a digest of the concatenated source files
          asset = env.find_asset(logical_path, :process => false)
          @source_digests[logical_path] = asset.digest
          # Recompile if digest has changed or compiled digest file is missing
          current_digest_file = @current_digest_files[logical_path]
          if @source_digests[logical_path] != @current_source_digests[logical_path] ||
             !(current_digest_file && File.exists?("#{@target}/#{current_digest_file}"))
            logical_paths << logical_path
          else
            # Set asset file from manifest.yml
            digest_file = @current_digest_files[logical_path]
            @digest_files[logical_path] = digest_file
            env.logger.debug "Not compiling #{logical_path}, sources digest has not changed " <<
                             "(#{@source_digests[logical_path][0...7]})"
          end
        end
        if processor_count > 1
          Rails.application.config.sass.cache = false
          Rails.application.config.sass.read_cache = false
        end
        # initialize workers
        workers = []
        processor_count.times do
          workers << worker(logical_paths)
        end
        reads = workers.map { |worker| worker[:read] }
        writes = workers.map { |worker| worker[:write] }
        index = finished = 0
        loop do
          break if finished >= logical_paths.size
          # monitor workers reads (precompiled assets) and writes (logical paths indexes)
          ready = IO.select(reads, writes)
          ready[0].each do |readable|
            # get precompiled asset from worker/child process
            job = Marshal.load(readable)
            @digest_files[job[:logical_path]] = job[:asset]
            finished += 1
          end
          ready[1].each do |write|
            break if index >= logical_paths.size
            Marshal.dump(index, write)
            index += 1
          end
        end
        workers.each do |worker|
          worker[:read].close
          worker[:write].close
        end
        workers.each do |worker|
          Process.wait worker[:pid]
        end

        # Encode all keys and values as UTF-8 for Ruby 1.9, otherwise YAML stores them as !binary
        if RUBY_VERSION.to_f >= 1.9
          utf8_sources, utf8_digests = {}, {}
          @source_digests.each { |k, v| utf8_sources[k.encode("UTF-8")] = v.encode("UTF-8") }
          @digest_files.each   { |k, v| utf8_digests[k.encode("UTF-8")] = v.encode("UTF-8") }
          @source_digests, @digest_files = utf8_sources, utf8_digests
        end

        if @manifest
          write_manifest(:source_digests => @source_digests, :digest_files => @digest_files)
        end

        # Store digests in Rails config. (Important if non-digest is run after primary)
        config = ::Rails.application.config
        config.assets.digest_files   = @digest_files
        config.assets.source_digests = @source_digests

        elapsed_time = ((Time.now.to_f - start_time) * 1000).to_i
        env.logger.debug "Processed #{'non-' unless @digest}digest assets in #{elapsed_time}ms"
      end

      def worker(logical_paths)
        child_read, parent_write = IO.pipe # pipe to get messages from parent process
        parent_read, child_write = IO.pipe # pipe to send messages to parent process
        pid = fork do
          begin
            parent_write.close
            parent_read.close
            while !child_read.eof?
              logical_path = logical_paths[Marshal.load(child_read)] # get asset logical path to process from parent
              asset = env.find_asset(logical_path)
              if asset
                # send precompiled asset to parent process
                Marshal.dump({
                                 :logical_path => logical_path,
                                 :asset => write_asset(asset),
                                 :asset_digest_path => asset.digest_path
                             }, child_write)
              end
            end
          ensure # close pipes file descriptors even if something goes wrong
            child_read.close
            child_write.close
          end
        end
        child_read.close
        child_write.close
        { :read => parent_read, :write => parent_write, :pid => pid }
      end

    end
  end
end
