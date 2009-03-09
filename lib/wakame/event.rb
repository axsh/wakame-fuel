
require 'mutex_m'
require 'sync'

require 'wakame'

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
    
    include Wakame

    def initialize
      extend(Sync_m)
      @event_handlers = {}
      @event_handlers.extend(Sync_m)
      @tickets = {}

      @unsubscribe_queue = []

      @handler_run_queue = Queue.new
      @handler_run_t = Thread.new {
        while h = @handler_run_queue.pop
          begin
            h.call
          rescue => e
            Wakame.log.error(e)
          end
        end
      }
      @handler_run_t[:name]="#{self.class} handler"
    end

    def subscribe(event_class, *args, &blk)
      event_class = event_class.is_a?(Class) ? event_class : event_class.class
      self.synchronize {
        tlist = @event_handlers[event_class]
        
        if tlist.nil?
          #@event_handlers.synchronize {
          tlist = @event_handlers[event_class] = []
          tlist.extend(Sync_m)
          #}
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
        return tickets.size > 1 ? tickets : tickets.first
      }
    end
    
    def unsubscribe(ticket)
      self.synchronize {
      ary = @tickets.delete(ticket)
      return nil if ary.nil?
      log.debug("Event unsubscribe(#{ticket})")

      tlist = @event_handlers[ary[0]]
      if tlist.locked?
        @unsubscribe_queue << ticket
      else
        #tlist.synchronize {
          tlist.delete(ticket)
        #}
      end
      ticket
      }
    end
    
    def fire_event(event_obj)
      raise TypeError unless event_obj.is_a?(Event::Base)
      log_msg = ""
      log_msg = " #{event_obj.log_message}" unless event_obj.log_message.nil?

      log.debug("Event #{event_obj.class} has been fired:" + log_msg )
      tlist = @event_handlers[event_obj.class]
      return if tlist.nil?

      run_handlers = proc {
        self.synchronize {
          #tlist.synchronize {
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
              raise e
            end
              
          }

          while t = @unsubscribe_queue.pop
            tlist.delete(t)
          end
        }
      }

      @handler_run_queue.push(run_handlers)
    end
    
    def reset(event_class=nil)
      self.synchronize {
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
      }
    end

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



    class AgentShutdown < Base; end
    class MasterShutdown < Base; end

  end
end
