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
        @current_digests        = options.fetch(:digests,   {})

        @digests        = {}
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
        lp = []
        env.each_logical_path do |logical_path|
          if File.basename(logical_path)[/[^\.]+/, 0] == 'index'
            logical_path.sub!(/\/index\./, '.')
          end
          next unless compile_path?(logical_path)
          if asset = env.find_asset(logical_path, :process => false)
            @source_digests[logical_path] = asset.digest
            current_digest_file = @current_digests[logical_path]
            if @source_digests[logical_path] != @current_source_digests[logical_path] ||
                !(current_digest_file && File.exists?("#{@target}/#{current_digest_file}"))
              lp << logical_path
            else
              digest_file = @current_digests[logical_path]
              @digests[logical_path] = digest_file
              env.logger.debug "Not compiling #{logical_path}, sources digest has not changed " <<
                                   "(#{@source_digests[logical_path][0...7]})"
            end
          end
        end
        puts "lp size: #{lp.size}"
        # get number of available CPU cores and disable Sass cache if there are multiple cores available
        # Sass caches compiled assets to the filesystem (single file) and we can't control concurrency access to it
        if processor_count > 1
          Rails.application.config.sass.cache = false
          Rails.application.config.sass.read_cache = false
        end
        # initialize workers
        workers = []
        processor_count.times do
          workers << worker(lp)
        end
        reads = workers.map { |worker| worker[:read] }
        writes = workers.map { |worker| worker[:write] }
        index = finished = 0
        loop do
          break if finished >= lp.size
          ready = IO.select(reads, writes) # monitor workers reads (precompiled assets) and writes (logical paths indexes)
          ready[0].each do |readable|
            job = Marshal.load(readable) # get precompiled asset from worker/child process
            @digests[job[:logical_path]] = job[:asset]
            # Update current_digests with new hash, for future assets to reference
            @current_digests[job[:logical_path]] = job[:asset_digest_path]
            finished += 1
          end
          ready[1].each do |write|
            break if index >= lp.size
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

        # Encode all filenames & digests as UTF-8 for Ruby 1.9,
        # otherwise YAML dumps other string encodings as !binary
        if RUBY_VERSION.to_f >= 1.9
          @source_digests = encode_hash_as_utf8 @source_digests
          @digests        = encode_hash_as_utf8 @digests
        end

        if @manifest
          write_manifest(@digests)
          write_sources_manifest(@source_digests)
        end

        # Store digests in Rails config. (Important if non-digest is run after primary)
        config = ::Rails.application.config
        config.assets.digests        = @digests
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

      def write_sources_manifest(source_digests)
        FileUtils.mkdir_p(@manifest_path)
        File.open("#{@manifest_path}/sources_manifest.yml", 'wb') do |f|
          YAML.dump(source_digests, f)
        end
      end

      private

      def encode_hash_as_utf8(hash)
        Hash[*hash.map {|k,v| [k.encode("UTF-8"), v.encode("UTF-8")] }.flatten]
      end
    end
  end
end
