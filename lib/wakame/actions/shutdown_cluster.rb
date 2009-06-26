module Wakame
  module Actions
    class ShutdownCluster < Action
      def run
        levels = service_cluster.dg.levels

        levels.reverse.each { |lv|
          lv.each { |svc_prop|
            service_cluster.each_instance(svc_prop.class) { |svc_inst|
              trigger_action(StopService.new(svc_inst))
            }
          }
          flush_subactions
        }

        agent_monitor.registered_agents.each { |id, agent|
          trigger_action(ShutdownVM.new(agent))
        }
      end
    end
  end
end
