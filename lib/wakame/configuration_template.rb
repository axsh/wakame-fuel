
require 'fileutils'

module Wakame
  module ConfigurationTemplate
    class Base
      attr_reader :tmp_output_basedir
      
      def initialize()
      end


      def pre_render
        @tmp_output_basedir = File.expand_path(Wakame.gen_id, Wakame.config.config_tmp_root)
        FileUtils.mkdir_p @tmp_output_basedir
      end

      def render(service_instance)
      end

      def post_render
        
      end

      # Returns source path which to be synced to the agent host
      def sync_src
      end


      protected
      def load(path)
        path = path.sub(/^\//, '')

        return File.readlines(File.expand_path(path, Wakame.config.config_template_root), "r").join('')
      end
      
      def save(path, buf)
        path = path.sub(/^\//, '')

        destpath = File.expand_path(path, @tmp_output_basedir)
        FileUtils.mkpath(File.dirname(destpath)) unless File.directory?(File.dirname(destpath))

        File.open(destpath, "w", 0644) {|f|
          f.write(buf)
        }
      end
      
      def update(path, &blk)
        buf = load(path)
        buf = yield buf if block_given?
        save(path, buf)
      end


    end

    class MySQLTemplate  < Base
      def render(service_instance)
        require 'erb'
        
        FileUtils.mkpath File.expand_path('mysql', tmp_output_basedir)

        ["mysql/my.cnf"].each { |path|
          update(path) { |buf|
            ERB.new(buf, nil, '-').result service_instance.export_binding
          }
        }
      end

      
      def sync_src
        File.join(@tmp_output_basedir, 'mysql')
      end
    end

    class MySQLSlaveTemplate  < Base
      def render(service_instance)
        require 'erb'
        
        FileUtils.mkpath File.expand_path('mysql-slave', tmp_output_basedir)

        ["mysql-slave/my-slave.cnf"].each { |path|
          update(path) { |buf|
            ERB.new(buf, nil, '-').result service_instance.export_binding
          }
        }
      end

      
      def sync_src
        File.join(@tmp_output_basedir, 'mysql-slave')
      end
    end

    class ApacheTemplate  < Base
      attr_accessor :suffix

      def initialize(suffix)
        super()
        @suffix = suffix
      end
      
      def render(service_instance)
#p service_instance.service_cluster.virtual_hosts
        require 'erb'
        
        FileUtils.mkpath File.expand_path('apache2', tmp_output_basedir)

        ["envvars-#{@suffix}", "apache2.conf"].each { |fname|
          FileUtils.cp_r(File.join(Wakame.config.config_template_root, "apache2/#{fname}"),
                         File.join(tmp_output_basedir, "apache2/#{fname}"),
                         {:preserve=>true})
        }

        ["apache2/system-#{@suffix}.conf", "apache2/sites-#{@suffix}.conf"].each { |path|
          update(path) { |buf|
            ERB.new(buf, nil, '-').result service_instance.export_binding
          }
        }
      end

      
      def sync_src
        File.join(@tmp_output_basedir, 'apache2')
      end
      
    end


  end

  
end
