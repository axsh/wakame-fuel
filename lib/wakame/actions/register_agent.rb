module Wakame
  module Actions
    class RegisterAgent < Action
      def initialize(agent)
        @agent = agent
      end

      def run
        Wakame.log.debug("#{self.class}: run() begin: #{@agent.id}")
        
        acquire_lock("Agent:#{@agent.id}")

        @agent.update_vm_attr
        
        # Send monitoring conf
        master.actor_request(@agent.id, '/monitor/reload', '/service', {}).request.wait

        StatusDB.barrier {
          @agent.update_status(Service::Agent::STATUS_RUNNING)
          Service::AgentPool.instance.register(@agent)
        }
        Wakame.log.debug("#{self.class}: run() end: #{@agent.id}")
      end

      def on_fail
        StatusDB.barrier {
          @agent.update_status(Service::Agent::STATUS_FAIL)
          Service::AgentPool.instance.unregister(@agent)
        }
      end

    end
  end
end
