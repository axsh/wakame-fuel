module Wakame
  module Actions
    class ShutdownVM < Action
      def initialize(agent)
        @agent = agent
      end

      def run
        
        if @agent.agent_id == master.master_local_agent_id
          Wakame.log.info("Skip to shutdown VM as the master is running on this node: #{@agent.agent_id}")
          return
        end

        VmManipulator.create.stop_instance(@agent[:instance_id])
      end
    end
  end
end
