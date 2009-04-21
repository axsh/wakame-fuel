
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

      class MigrateService
        attr_reader :service_instance, :agent
        def initialize(svc_inst, agent=nil)
          @service_instance = svc_inst
          @agent = agent
        end
      end

    end

    class CommandDelegator

      attr_reader :command_queue
      def initialize(command_queue)
        @command_queue = command_queue
      end

      def nop
        @command_queue.send_cmd(Commands::Nop.new)
      end
      
      def launch_cluster
        @command_queue.send_cmd(Commands::ClusterLaunch.new)
      end

      def shutdown_cluster
        @command_queue.send_cmd(Commands::ClusterShutdown.new)
      end
      def propagate_service(prop_name)
        prop = nil
        prop = master.service_cluster.properties[prop_name.to_s]
        if prop.nil?
          raise "UnknownProperty: #{prop_name}" 
        end

        @command_queue.send_cmd(Commands::PropagateService.new(prop))
      end
      def migrate_service(svc_inst_id, agent_id=nil)
        svc = master.service_cluster.instances[svc_inst_id]
        if svc.nil?
          raise "Unknown Service Instance: #{svc_inst_id}" 
        end
        agent = nil
        if agent_id
          agent = master.agent_monitor.agents.has_key?(agent_id)
          if agent.nil?
            raise "Unknown Agent: #{agent_id}" 
          end
        end

        @command_queue.send_cmd(Commands::MigrateService.new(svc, agent))
      end
      def deploy_config(prop_name=nil)
        prop = nil
        @command_queue.send_cmd(Commands::DeployConfig.new)
      end

      def status
        EM.barrier {
          master = Master.instance
          
          sc = master.service_cluster
          result = {
            :rule_engine => {
              :rules => sc.rule_engine.rules
            },
            :service_cluster => sc.dump_status,
            :agent_monitor => master.agent_monitor.dump_status
          }
          result
        }
      end

      def action_status
        walk_subactions = proc { |a, level|
          res = a.dump_attrs
          unless a.subactions.empty?
            res[:subactions] = a.subactions.collect { |s|
              walk_subactions.call(s, level + 1)
            }
          end
          res
        }

        EM.barrier {
          result = {}
          Master.instance.service_cluster.rule_engine.active_jobs.each { |id, v|
            result[id]={:actions=>[], :created_at=>v[:created_at], :src_rule=>v[:src_rule].class.to_s}

            result[id][:root_action] = walk_subactions.call(v[:root_action], 0)
          }

          result
        }
      end


      private
      def master
        command_queue.master
      end

    end

  end
end
