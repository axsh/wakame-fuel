module Wakame
  module Trigger
    include FilterChain
    include AttributeHelper

    def_attribute :enabled, true

    attr_reader :rule_engine
    def command_queue
      @rule_engine.command_queue
    end

    def service_cluster
      @rule_engine.service_cluster
    end

    def master
      @rule_engine.master
    end

    def agent_monitor
      @rule_engine.agent_monitor
    end

    def bind_engine(rule_engine)
      @rule_engine = rule_engine
    end

    def trigger_action(action)
      found = rule_engine.active_jobs.find { |id, job|
        job[:src_rule].class == self.class
      }

      if found
        Wakame.log.warn("#{self.class}: Exisiting Job \"#{found[:job_id]}\" was kicked from this rule and it's still running. Skipping...")
        raise CancelActionError
      end

      rule_engine.create_job_context(self, action)
      action.bind_triggered_rule(self)
      
      rule_engine.run_action(action)
      action.job_id
    end

    def register_hooks
    end

    def cleanup
    end

    protected
    def event_subscribe(event_class, &blk)
      EventDispatcher.subscribe(event_class) { |event|
        begin
          run_filter(self)
          blk.call(event) if self.enabled 
        rescue => e
          Wakame.log.error(e)
        end
      }
    end

  end

end
