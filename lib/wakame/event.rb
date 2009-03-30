
require 'wakame'
require 'wakame/util'

module Wakame
  class EventHandler
    class << self
      
      def instance
        if @instance.nil?
          @instance = self.new
        end
        @instance
      end
      
      def subscribe(event_class, *args, &blk)
        self.instance.subscribe(event_class, *args, &blk)
      end

      def unsubscribe(event_class)
        self.instance.unsubscribe(event_class)
      end


      def fire_event(event_obj)
        self.instance.fire_event(event_obj)
      end

      def reset
        @instance = nil
      end

    end
    
    include ThreadImmutable
    include Wakame

    def initialize
      @event_handlers = {}
      @tickets = {}

      @unsubscribe_queue = []
    end

    def subscribe(event_class, *args, &blk)
      event_class = case event_class
                    when Class
                      event_class
                    when String
                      Wakame.str2const(event_class)
                    else
                      raise ArgumentError, "event_class has to be a form of String or Class type"
                    end

      EM.barrier {
      tlist = @event_handlers[event_class]
      if tlist.nil?
        tlist = @event_handlers[event_class] = []
      end
      
      tickets = []
      args.each { |o|
        tickets << Wakame.gen_id
        @tickets.store(tickets.last, [event_class, o])
        tlist << tickets.last
      }
      
      if blk
        tickets << Wakame.gen_id
        @tickets.store(tickets.last, [event_class, blk])
        tlist << tickets.last
      end

        # Return in array if num of ticket to be returned is more than or equal 2.
        tickets.size > 1 ? tickets : tickets.first
      }
    end

    def unsubscribe(ticket)
      unless @tickets.has_key?(ticket)
        #Wakame.log.warn("EventHander.unsubscribe(#{ticket}) has been tried but the ticket was not registered.")
        return nil
      end
      
      EM.barrier {
        log.debug("EventHandler.unsubscribe(#{ticket})")

        @unsubscribe_queue << ticket
        ticket
      }
    end
    
    def fire_event(event_obj)
      raise ArgumentError unless event_obj.is_a?(Event::Base)
      log_msg = ""
      log_msg = " #{event_obj.log_message}" unless event_obj.log_message.nil?

      log.debug("Event #{event_obj.class} has been fired:" + log_msg )
      tlist = @event_handlers[event_obj.class]
      return if tlist.nil?

      run_callbacks = proc {
        @unsubscribe_queue.each { |t|
          @tickets.delete(t)
          tlist.delete(t)
        }

        tlist.each { |t|
          ary = @tickets[t]
          c = ary[1]
          if c.nil?
            next
          end
          
          begin 
            c.call(event_obj)
          rescue => e
            log.error(e)
            #raise e
          end
        }
        
        @unsubscribe_queue.each { |t|
          @tickets.delete(t)
          tlist.delete(t)
        }
      }
    
      #@handler_run_queue.push(run_handlers)
      EventMachine.next_tick {
        begin 
          run_callbacks.call
        rescue => e
          Wakame.log.error(e)
        end
      }
    end
    
    def reset(event_class=nil)
      if event_class.nil?
        @event_handlers.clear
        @tickets.clear
      else
        unless @event_handlers[event_class.to_s].nil?
          @event_handlers[event_class.to_s].each_key { |k|
            @tickets.delete(k)
          }
          @event_handlers[event_class.to_s].clear
        end
      end
    end
    thread_immutable_methods :reset

  end

  EH = EventHandler


  module Event
    class Base
      attr_accessor :time

      def initialize
        @time = Time.now
      end

      def log_message
      end
    end


    class ClusterStatusChanged  < Base
      attr_reader :instance_id, :status
      def initialize(instance_id, status)
        super()
        @instance_id = instance_id
        @status = status
      end

      def log_message
        "#{instance_id}, #{@status}"
      end

    end

    class ServiceStatus < Base
      attr_reader :instance_id, :property
      def initialize(instance_id, property)
        super()
        @instance_id = instance_id
        @property = property
      end
    end

    class ServiceStatusChanged < ServiceStatus
      attr_reader :status, :previous_status
      def initialize(instance_id, property, new_status, prev_status)
        super(instance_id, property)
        @status = new_status
        @previous_status = prev_status
      end

      def log_message
        "#{instance_id}, #{@previous_status} -> #{@status}"
      end
    end

    class ServiceOnline < ServiceStatus
    end
    class ServiceOffline < ServiceStatus
    end
    class ServiceFailed < ServiceStatus
      attr_reader :message
      def initialize(instance_id, property, message)
        super(instance_id, property)
        @message = message
      end
    end

    class AgentEvent < Base
      attr_reader :agent
      def initialize(agent)
        super()
        @agent = agent
      end
    end

    class AgentPong < AgentEvent
    end

    class AgentTimedOut < AgentEvent
    end
    class AgentMonitored < AgentEvent
    end
    class AgentUnMonitored < AgentEvent
    end
    class AgentStatusChanged < AgentEvent
    end


    class ServiceUnboundAgent < Base
      attr_reader :service, :agent
      def initialize(service, agent)
        super()
        @service = service
        @agent = agent
      end
    end
    class ServiceBoundAgent < Base
      attr_reader :service, :agent
      def initialize(service, agent)
        super()
        @service = service
        @agent = agent
      end
    end

    class ServiceBoundCluster < Base
      attr_reader :service, :service_cluster
      def initialize(svc_inst, cluster)
        super()
        @service = svc_inst
        @service_cluster = cluster
      end
    end

    class ServiceUnboundCluster < Base
      attr_reader :service, :service_cluster
      def initialize(svc_inst, cluster)
        super()
        @service = svc_inst
        @service_cluster = cluster
      end
    end

    class ServiceDestroied < Base
      attr_reader :service
      def initialize(svc_inst)
        super()
        @service = svc_inst
      end
    end

    class ServicePropagated < Base
      attr_reader :service
      def initialize(svc_inst)
        super()
        @service = svc_inst
      end
    end

    class CommandReceived < Base
      attr_reader :command
      def initialize(command)
        @command = command
      end
    end

    class ActionEvent < Base
      attr_reader :action
      def initialize(action)
        super()
        @action = action
      end

      def log_message
        "#{@action.class}"
      end

    end

    class ActionStart < ActionEvent
    end
    class ActionComplete < ActionEvent
    end
    class ActionFailed < ActionEvent
      attr_reader :exception
      def initialize(action, e)
        super(action)
        @exception = e
      end
    end

    class JobEvent < Base
      attr_reader :job_id
      def initialize(job_id)
        super()
        @action = job_id
      end

      def log_message
        "#{@action.class}"
      end
    end
    class JobStart < JobEvent
    end
    class JobComplete < JobEvent
    end
    class JobFailed < JobEvent
      attr_reader :exception
      def initialize(job_id, e)
        super(job_id)
        @exception = e
      end
    end
    

    class AgentShutdown < Base; end
    class MasterShutdown < Base; end

  end
end
