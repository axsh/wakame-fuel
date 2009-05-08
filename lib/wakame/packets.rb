#!/usr/bin/ruby

require 'wakame/agent'
require 'wakame/util'

module Wakame
  module Packets

    module Agent
      class ResponseBase
        include AttributeHelper

        attr_reader :agent_id, :response_time
        
        def initialize(agent)
          raise TypeError unless agent.respond_to?(:agent_id)

          @agent_id = agent.agent_id.to_s
          @response_time = Time.now
        end
        protected :initialize

        def marshal
          dump_attrs.inspect
        end
        
      end
      
      class RequestBase
        include AttributeHelper

        attr_reader :token, :request_time

        def initialize()
          @token = Util.gen_id
          @request_time = Time.now
        end
        protected :initialize

        def marshal
          dump_attrs.inspect
        end
      end
      
      class Ping < ResponseBase
        attr_reader :attrs, :monitors, :actors
        def initialize(agent, attrs, actors, monitors)
          super(agent)
          @attrs = attrs
          @actors = actors
          @monitors = monitors
        end
      end
      

      class Register < ResponseBase
        def initialize(agent)
          super(agent)
        end
      end

      class UnRegister < ResponseBase
        def initialize(agent)
          super(agent)
        end
      end

      class MonitoringStarted < ResponseBase
        attr_reader :svc_id
        def initialize(agent, svc_id)
          super(agent)
          @svc_id = svc_id
        end
      end

      class MonitoringStopped < ResponseBase
        attr_reader :svc_id
        def initialize(agent, svc_id)
          super(agent)
          @svc_id = svc_id
        end
      end
      class MonitoringOutput < ResponseBase
        attr_reader :svc_id, :outputs
        def initialize(agent, svc_id, outputs)
          super(agent)
          @svc_id = svc_id
          @outputs = outputs
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

      class ServiceStatusChanged < ResponseBase
        attr_accessor :svc_id, :prev_status, :new_status
        def initialize(agent, svc_id, prev_status, new_status)
          super(agent)
          @svc_id = svc_id
          @prev_status = prev_status
          @svc_id = svc_id
          @svc_id = svc_id
        end
      end


      class ActorRequest < RequestBase
        attr_reader :agent_id, :path, :args
        def initialize(agent_id, path, args)
          super()
          @agent_id = agent_id
          @path = path
          @args = args
        end
      end

    end
  end
end
