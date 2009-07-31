
require 'fileutils'
require 'erb'

module Wakame
  class Template
    attr_accessor :service_instance
    attr_reader :tmp_basedir

    def initialize(service_instance)
      @service_instance = service_instance
      @tmp_basedir = File.expand_path(Util.gen_id, File.join(Wakame.config.root_path, 'tmp', 'config') )
      FileUtils.mkdir_p @tmp_basedir
    end

    def basedir
      @service_instance.resource.basedir
    end

    def render_config
      service_instance.property.render_config(self)
    end

    def cleanup
      FileUtils.rm_r( @tmp_basedir, :force=>true)
    end

    def render(args)
      args = [args] if args.is_a? String
      
      args.each { |path|
        update(path) { |buf|
          ERB.new(buf, nil, '-').result(service_instance.export_binding)
        }
      }
    end

    def cp(args)
      args = [args] if args.is_a? String
      args.each { |fname|

        destpath = File.expand_path(fname, @tmp_basedir)
        FileUtils.mkpath(File.dirname(destpath)) unless File.directory?(File.dirname(destpath))

        FileUtils.cp_r(File.join(basedir, fname),
                       destpath,
                       {:preserve=>true}
                       )
      }
    end

    def chmod(fname, mode)
      File.chmod(mode, File.join(@tmp_basedir, fname))
    end

    def load(path)
      path = path.sub(/^\//, '')
      
      return File.readlines(File.expand_path(path, basedir), "r").join('')
    end
    
    def save(path, buf)
      path = path.sub(/^\//, '')
      
      destpath = File.expand_path(path, @tmp_basedir)
      FileUtils.mkpath(File.dirname(destpath)) unless File.directory?(File.dirname(destpath))
      
      File.open(destpath, "w", 0644) { |f|
        f.write(buf)
      }
    end
    
    def update(path, &blk)
      buf = load(path)
      buf = yield buf if block_given?
      save(path, buf)
    end
    
  end
  
end
