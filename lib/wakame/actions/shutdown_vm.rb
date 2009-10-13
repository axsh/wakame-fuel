module Wakame
  module Actions
    class ShutdownVM < Action
      def initialize(agent)
        raise ArgumentError unless agent.is_a?(Service::Agent)
        @agent = agent
      end

      def run
        #if @agent.id == master.master_local_agent_id
        #  Wakame.log.info("Skip to shutdown VM as the master is running on this node: #{@agent.agent_id}")
        #  return
        #end
        
        shutdown_ec2_instance

      end

      private
      def shutdown_ec2_instance
        require 'right_aws'
        ec2 = RightAws::Ec2.new(Wakame.config.aws_access_key, Wakame.config.aws_secret_key, {:cache=>false})

        res = ec2.terminate_instances([@agent.vm_attr[:aws_instance_id]])
      end
    end
  end
end
