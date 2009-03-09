
module Wakame
  module Manager
    module Commands

      class Nop
      end

      class ClusterLaunch
      end

      class ClusterShutdown
      end
      
      class DeployConfig
        attr_reader :property
        def initialize(prop=nil)
          @property = prop
        end
      end

      class PropagateService
        attr_reader :property
        def initialize(prop)
          @property = prop
        end
      end

    end

    class CommandDelegator
      attr_reader :command_queue
      def initialize(command_queue)
        @command_queue = command_queue
      end
      
      def launch_cluster
        @command_queue.send_cmd(Commands::ClusterLaunch.new)
      end

      def shutdown_cluster
        @command_queue.send_cmd(Commands::ClusterShutdown.new)
      end
      def propagate_service(prop_name)
        prop = nil
        master.service_cluster.synchronize {
          prop = master.service_cluster.properties[prop_name.to_s]
          if prop.nil?
            raise "UnknownProperty: #{prop_name}" 
          end
        }

        @command_queue.send_cmd(Commands::PropagateService.new(prop))
      end
      def deploy_config(prop_name=nil)
        prop = nil
        @command_queue.send_cmd(Commands::DeployConfig.new)
      end

      def status
        master = Master.instance

        sc = master.service_cluster
        result = {
          :rule_engine => {
            :rules => sc.rule_engine.rules
          },
          :service_cluster => sc.dump_status,
          :agent_monitor => master.agent_monitor.dump_status
        }

        #return JSON.generate(result)
        return result
      end


      private
      def master
        command_queue.master
      end

    end

  end
end
