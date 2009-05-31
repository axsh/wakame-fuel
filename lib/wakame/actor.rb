

module Wakame
  module Actor
    STATUS_RUNNING = 1
    STATUS_SUCCESS = 2
    STATUS_FAILED = 0
    STATUS_CANCELED = 3

    def self.included(klass)
      klass.extend ClassMethods
      klass.class_eval {
        attr_accessor :agent
      }
    end

    module ClassMethods
      def expose(path, meth)
        @exposed ||= {}
        @exposed[path]=meth
      end

      def map_path
        @map_path ||= Util.snake_case(self.to_s.split('::').last)
      end
      
      def map_path=(name)
        @map_path=name
      end
    end
    
  end
end
