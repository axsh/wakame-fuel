module Wakame
  class Action
    include AttributeHelper
    include ThreadImmutable
    
    def_attribute :job_id
    def_attribute :status, :ready
    def_attribute :completion_status
    def_attribute :parent_action
    def_attribute :acquire_lock, false
    
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
    
    def bind_triggered_rule(trigger)
      @trigger = trigger
    end
    
    def trigger_action(subaction, opts={})
      if opts.is_a? Hash
        succ_proc = opts[:success] || opts[:succ]
        fail_proc = opts[:fail]
      end
      subactions << subaction
      subaction.parent_action = self
      #subaction.observers << self
      
      async_trigger_action(subaction, succ_proc, fail_proc)
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
    
    def run
      raise NotImplementedError
    end
    
    def on_failed
    end
    
    def on_canceled
    end
    
    private
    def sync_trigger_action(action, succ_proc, fail_proc)
      action.job_id = self.job_id
      action.bind_triggered_rule(self.trigger)
      
      Wakame.log.debug("Start nested action in SYNC: #{action.class.to_s}")
      begin
        action.run
        succ_proc.call if succ_proc
      rescue => e
        fail_proc.call if fail_proc
        raise
      end
      Wakame.log.debug("Complete nested action : #{action.class.to_s}")
    end
    
    def async_trigger_action(action, succ_proc, fail_proc)
      action.job_id = self.job_id
      action.bind_triggered_rule(self.trigger)
      
      trigger.rule_engine.run_action(action)
    end
    
  end
end
