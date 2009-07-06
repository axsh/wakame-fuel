
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

    def initialize(option)
      @options = option
    end

    def parse(args)
    end

    def run(rule)
    end

    def print_result
    end

  end
end
