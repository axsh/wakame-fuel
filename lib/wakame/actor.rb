

module Wakame
  module Actor
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
    end
    
  end
end
