
WAKAME_ENV = (ENV['WAKAME_ENV'] || 'StandAlone').dup.to_sym unless defined?(WAKAME_ENV)

module Wakame
  class Initializer

    class << self
      def run(command, configuration=Configuration.new)
        @instance ||= new(configuration)
        @instance.send(command)
      end

      def instance
        @instance
      end
    end

    attr_reader :configuration

    def initialize(configuration)
      @configuration = configuration
    end

    def process
      setup_load_paths
      setup_logger
      load_environment
    end

    def process_master
      process
      load_cluster
      load_resources
      load_core_commands
      load_core_actions
      load_core_triggers
    end
    
    def process_agent
      process
      load_actors
    end
    
    def process_cli
      process
      load_core_commands
    end

    def setup_load_paths
      load_paths = configuration.load_paths + configuration.framework_paths
      load_paths.reverse_each { |dir| $LOAD_PATH.unshift(dir) if File.directory?(dir) }
      $LOAD_PATH.uniq!

      require 'wakame'
    end

    def setup_logger
      require 'log4r'
      Logger.log = begin
                     #log = Logger.new((Wakame.root||Dir.pwd) / "log.log")
                     out = ::Log4r::StdoutOutputter.new('stdout',
                                                        :formatter => Log4r::PatternFormatter.new(
                                                                                                  :pattern => "%d %C [%l]: %M",
                                                                                                  :date_format => "%Y/%m/%d %H:%M:%S"
                                                                                                  )
                                                        )
                     log = ::Log4r::Logger.new(File.basename($0.to_s))
                     log.add(out)
                     log
                   end
    end


    def setup_system_actors
    end

    def load_system_monitors
    end

    def load_core_commands
#       %w( cluster/commands ).each { |load_path|
#         load_path = File.expand_path(load_path, configuration.root_path)
#         matcher = /\A#{Regexp.escape(load_path)}(.*)\.rb\Z/
#         Dir.glob("#{load_path}/**/*.rb").sort.each do |file|
#           require file.sub(matcher, '\1')
#         end
#       }

      $LOAD_PATH.each{ |d|
        Dir.glob("#{d}/wakame/command/**/*.rb").each{ |f|
          f =~ %r{(wakame/command/.+)\.rb\Z}
          require "#{$1}"
        }
      }
      
      #%w(launch_cluster shutdown_cluster status action_status actor).each { |f|
      #  require "wakame/command/#{f}"
      #}
    end


    def load_environment
      config = configuration
      constants = self.class.constants

      [:common, config.environment].each { |key|
        eval(IO.read(config.environment_path(key)), binding, config.environment_path(key))
      }

      (self.class.constants - constants).each do |const|
        Object.const_set(const, self.class.const_get(const))
      end
    end

    def load_resources
      load_path = File.expand_path('cluster/resources', configuration.root_path)
      Dir.glob("#{load_path}/*/*.rb").sort.each do |file|
        if file =~ %r{\A#{Regexp.escape(load_path)}/([^/]+)/([^/]+)\.rb\Z} && $1 == $2
          Wakame.log.debug("Loading resource definition: #{file}")
          load file
        end
        #require file.sub(matcher, '\1')
      end
      
    end


    def load_cluster
      load File.expand_path('config/cluster.rb', configuration.root_path)
    end

    def load_actors
      load_path = File.expand_path('cluster/actors', configuration.root_path)
      Dir.glob("#{load_path}/*.rb").sort.each do |file|
        if file =~ %r{\A#{Regexp.escape(load_path)}/([^/]+)\.rb\Z}
          Wakame.log.debug("Loading Actor: #{file}")
          load file
        end
      end
    end

    def load_core_triggers
      $LOAD_PATH.each{ |d|
        Dir.glob("#{d}/wakame/triggers/**/*.rb").each{ |f|
          f =~ %r{(wakame/triggers/.+)\.rb\Z}
          require "#{$1}"
        }
      }
    end

    def load_core_actions
      $LOAD_PATH.each{ |d|
        Dir.glob("#{d}/wakame/actions/**/*.rb").each{ |f|
          f =~ %r{(wakame/actions/.+)\.rb\Z}
          require "#{$1}"
        }
      }
    end


  end
end
