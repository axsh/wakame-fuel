module Wakame
  module Actions
    class ShutdownCluster < Action
      def run
        levels = cluster.dg.levels
        Wakame.log.debug("#{self.class}: Resource shutdown order: " + levels.collect {|lv| '['+ lv.collect{|prop| "#{prop.class}" }.join(', ') + ']' }.join(', '))
        acquire_lock { |list|
          levels.each {|lv| list << lv.collect{|res| res.class } }
        }

        levels.reverse.each { |lv|
          lv.each { |svc_prop|
            service_cluster.each_instance(svc_prop.class) { |svc_inst|
              trigger_action(StopService.new(svc_inst))
            }
          }
          flush_subactions
        }

        agent_monitor.agent_pool.group_active.keys.each { |agent_id|
          trigger_action(ShutdownVM.new(Service::Agent.find(agent_id)))
        }
      end
    end
  end
end
