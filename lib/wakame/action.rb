module Wakame
  class Action
    include AttributeHelper
    include ThreadImmutable
    
    def_attribute :job_id
    def_attribute :status, :ready
    def_attribute :completion_status
    def_attribute :parent_action
    
    attr_reader :trigger

    def master
      trigger.master
    end
    
    def agent_monitor
      trigger.agent_monitor
    end
    
    def service_cluster
      trigger.service_cluster
    end
    
    alias :cluster :service_cluster


    def status=(status)
      if @status != status
        @status = status
        # Notify to observers after updating the attribute
        notify
      end
      @status
    end
    thread_immutable_methods :status=
      
    def subactions
      @subactions ||= []
    end
    
    def bind_trigger(trigger)
      @trigger = trigger
    end
    
    def trigger_action(subaction=nil, &blk)
      if blk 
        subaction = ProcAction.new(blk)
      end

      subactions << subaction
      subaction.parent_action = self
      subaction.job_id = self.job_id
      subaction.bind_trigger(self.trigger)
      
      trigger.rule_engine.run_action(subaction)
    end
    
    def flush_subactions(sec=nil)
      job_context = trigger.rule_engine.active_jobs[self.job_id]
      return if job_context.nil?
      
      timeout(sec.nil? ? nil : sec) {
        until all_subactions_complete?
          #Wakame.log.debug "#{self.class} all_subactions_complete?=#{all_subactions_complete?}"
          src = notify_queue.deq
          # Exit the current action when a subaction notified exception.
          if src.is_a?(Exception)
            raise src
          end
          #Wakame.log.debug "#{self.class} notified by #{src.class}, all_subactions_complete?=#{all_subactions_complete?}"
        end
      }
    end
    thread_immutable_methods :flush_subactions
    
    def all_subactions_complete?
      subactions.each { |a|
        #Wakame.log.debug("#{a.class}.status=#{a.status}")
        return false unless a.status == :complete && a.all_subactions_complete?
      }
      true
    end
    
    def notify_queue
      @notify_queue ||= ::Queue.new
    end
    
    def notify(src=nil)
      #Wakame.log.debug("#{self.class}.notify() has been called")
      src = self if src.nil?
      if status == :complete && parent_action
        # Escalate the notification to parent if the action is finished.
        parent_action.notify(src)
      else
        notify_queue.clear if notify_queue.size > 0
        notify_queue.enq(src) #if notify_queue.num_waiting > 0
      end
    end

    # Recursively iterate the sub action descendants.
    def walk_subactions(&blk)
      blk.call(self)
      self.subactions.each{ |a|
        a.walk_subactions(&blk)
      }
    end
    
    def actor_request(agent_id, path, *args, &blk)
      request = master.actor_request(agent_id, path, *args)
      if blk
        request.request
        blk.call(request)
      end
      request
    end
    
    def sync_actor_request(agent_id, path, *args)
      request = actor_request(agent_id, path, *args).request
      request.wait
    end
    
    def notes
      trigger.rule_engine.active_jobs[self.job_id][:notes]
    end

    # Set the lock flags to resources 
    def acquire_lock(&blk)
      StatusDB.barrier {
        reslist = []
        blk.call(reslist)
        reslist.flatten!
        reslist.each {|r| trigger.rule_engine.lock_queue.set(r.to_s, self.job_id) }
      }
      
      trigger.rule_engine.lock_queue.wait(self.job_id)
    end
    thread_immutable_methods :acquire_lock

    def run
      raise NotImplementedError
    end
    
    def on_failed
    end
    
    def on_canceled
    end


    class ProcAction < Action
      def initialize(proc_obj)
        raise ArgumentError unless proc_obj.is_a? Proc
        @proc_obj = proc_obj
      end

      def run()
        @proc_obj.call
      end
    end


  end


end
