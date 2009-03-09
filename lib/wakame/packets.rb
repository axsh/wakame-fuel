#!/usr/bin/ruby

require 'wakame/agent'

module Wakame
  module Packets

    module Agent
      class ResponseBase
        attr_reader :agent_id, :attr
        
        protected :initialize
        def initialize(agent)
          raise TypeError unless agent.respond_to?(:agent_id)

          @agent_id = agent.agent_id.to_s
          @attr = agent.attr if agent.respond_to?(:attr)
        end
      end
      
      class RequestBase
      end
      
      class Ping < ResponseBase
        attr_reader :services
        def initialize(agent, services=[])
          super(agent)
          @services = services
        end
      end
      

      class EventResponse < ResponseBase
        attr_reader :event
        def initialize(agent, event)
          super(agent)
          @event = event
        end
      end

      class Nop < RequestBase
      end

      class ServiceStart < RequestBase
        attr_reader :instance_id, :property
        def initialize(instance_id, property)
          @instance_id = instance_id
          @property = property
        end
      end

      class ServiceStop < RequestBase
        attr_reader :instance_id
        def initialize(instance_id)
          @instance_id = instance_id
        end
      end

      class ServiceReload < RequestBase
        attr_reader :instance_id
        def initialize(instance_id)
          @instance_id = instance_id
        end
      end

      class FileUpload < RequestBase
        attr_reader :path, :content
        def initialize(path, content)
          @path = path
          @content = content
        end
      end
      
    end
  end
end
