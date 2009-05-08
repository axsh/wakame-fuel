
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

    def process_master
      setup_load_paths
      setup_logger
    end
    
    def process_agent
      setup_load_paths
      setup_logger
    end
    
    def process_cli
      #$LOAD_PATH.
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

  end
end
