#!/usr/bin/ruby

require 'wakame/agent'
require 'wakame/util'

module Wakame
  module Packets
    VERSION='0.4'

    class ResponseBase
      include AttributeHelper

      attr_reader :agent_id, :responded_at
      
      def initialize(agent)
        raise TypeError unless agent.respond_to?(:agent_id)

        @agent_id = agent.agent_id.to_s
        @responded_at = Time.now
      end
      protected :initialize

      def marshal
        dump_attrs.inspect
      end
      
    end
    
    class RequestBase
      include AttributeHelper

      attr_reader :token, :requested_at

      def initialize(token=nil)
        @token = token || Util.gen_id
        @requested_at = Time.now
      end
      protected :initialize

      def marshal
        dump_attrs.inspect
      end
    end
    
    class Ping < ResponseBase
      attr_reader :attrs, :monitors, :actors, :services
      def initialize(agent, attrs, actors, monitors, services)
        super(agent)
        @attrs = attrs
        @actors = actors
        @monitors = monitors
        @services = services
      end
    end
    

    class Register < ResponseBase
      attr_reader :root_path, :attrs
      def initialize(agent, root_path, attrs)
        super(agent)
        @root_path = root_path
        @attrs = attrs
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

#     class ServiceStart < RequestBase
#       attr_reader :instance_id, :property
#       def initialize(instance_id, property)
#         @instance_id = instance_id
#         @property = property
#       end
#     end

#     class ServiceStop < RequestBase
#       attr_reader :instance_id
#       def initialize(instance_id)
#         @instance_id = instance_id
#       end
#     end

#     class ServiceReload < RequestBase
#       attr_reader :instance_id
#       def initialize(instance_id)
#         @instance_id = instance_id
#       end
#     end

    class ServiceStatusChanged < ResponseBase
      attr_accessor :svc_id, :prev_status, :new_status, :fail_message
      def initialize(agent, svc_id, prev_status, new_status, fail_message=nil)
        super(agent)
        @svc_id = svc_id
        @prev_status = prev_status
        @new_status = new_status
        @fail_message = fail_message
      end
    end

    class ActorRequest < RequestBase
      attr_reader :agent_id, :token, :path, :args
      def initialize(agent_id, token, path, *args)
        super()
        @agent_id = agent_id
        @token = token
        @path = path
        @args = args
      end
    end

    class ActorResponse < ResponseBase
      attr_reader :agent_id, :token, :status
      def initialize(agent, token, status)
        super(agent)
        @token = token
        @status = status
      end
    end

  end
end
