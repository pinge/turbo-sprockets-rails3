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
          @@cpu_cores ||= case RbConfig::CONFIG['host_os']
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
        logical_paths = env.each_logical_path.reject do |logical_path|
          logical_path.sub!(/\/index\./, '.') if File.basename(logical_path)[/[^\.]+/, 0] == 'index'
          !compile_path?(logical_path)
        end
        if processor_count > 1
          Rails.application.config.sass.cache = false
          Rails.application.config.sass.read_cache = false
        end
        workers = []
        (processor_count * 2).times do
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
            @source_digests[job[:logical_path]] = job[:asset_digest]
            if job[:processed]
              @digests[job[:logical_path]] = job[:asset]
              # Update current_digests with new hash, for future assets to reference
              @current_digests[job[:logical_path]] = job[:asset_digest_path]
            else
              digest_file = @current_digests[job[:logical_path]]
              @digests[job[:logical_path]] = digest_file
            end
            finished += 1
          end
          ready[1].each do |write|
            break if index >= logical_paths.size
            Marshal.dump([index, @source_digests], write)
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
      end

      def write_sources_manifest(source_digests)
        FileUtils.mkdir_p(@manifest_path)
        File.open("#{@manifest_path}/sources_manifest.yml", 'wb') do |f|
          YAML.dump(source_digests, f)
        end
      end

      def worker(logical_paths)
        child_read, parent_write = IO.pipe # pipe to get messages from parent process
        parent_read, child_write = IO.pipe # pipe to send messages to parent process
        pid = fork do
          begin
            parent_write.close
            parent_read.close
            while !child_read.eof?
              logical_path_index, source_digests = Marshal.load(child_read) # get asset logical path to process from parent
              logical_path = logical_paths[logical_path_index] # get asset logical path to process from parent
              if asset = env.find_asset(logical_path, :process => false)
                source_digests[logical_path] = asset.digest
                # Recompile if digest has changed or compiled digest file is missing
                current_digest_file = @current_digests[logical_path]
                #if false
                if source_digests[logical_path] != @current_source_digests[logical_path] ||
                    !(current_digest_file && File.exists?("#{@target}/#{current_digest_file}"))

                  if asset = env.find_asset(logical_path)
                    Marshal.dump({
                                     :processed => true,
                                     :logical_path => logical_path,
                                     :asset => write_asset(asset),
                                     :asset_digest => source_digests[logical_path],
                                     :asset_digest_path => asset.digest_path
                                 }, child_write)
                  end
                else
                  Marshal.dump({
                                   :processed => false,
                                   :logical_path => logical_path,
                                   :asset_digest => source_digests[logical_path]
                               }, child_write)
                end
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

      private

      def encode_hash_as_utf8(hash)
        Hash[*hash.map {|k,v| [k.encode("UTF-8"), v.encode("UTF-8")] }.flatten]
      end

    end
  end
end
