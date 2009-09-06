module Wakame
  class Trigger
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
    alias :cluster :service_cluster

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
      rule_engine.create_job_context(self, action)
      action.bind_trigger(self)
      
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
