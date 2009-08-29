
module Wakame
  module Command
    class CommandArgumentError < StandardError; end

    def self.included(klass)
      klass.class_eval {
        class << self
          def command_name
            @command_name ||= Util.snake_case(self.to_s.split('::').last)
          end
          
          def command_name=(name)
            @command_name=name
          end
        end
      }
    end

    def options=(path)
      @options = path
    end

    def params
      @options
    end

    def run(rule)
    end


  end
end
