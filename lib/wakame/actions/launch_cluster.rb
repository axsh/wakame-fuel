module Wakame
  module Actions
    class LaunchCluster < Action
      def initialize
      end

      def run
        if service_cluster.status == Service::ServiceCluster::STATUS_ONLINE
          Wakame.log.info("The service cluster is up & running already")
          raise CancelActionError
        end

        levels = service_cluster.dg.levels
        Wakame.log.debug("#{self.class}: Resource launch order: " + levels.collect {|lv| '['+ lv.collect{|prop| "#{prop.class}" }.join(', ') + ']' }.join(', '))
        acquire_lock { |list|
          levels.each {|lv| list << lv.collect{|res| res.class } }
        }

        levels.each { |lv|
          lv.each { |svc_prop|
            trigger_action(PropagateInstances.new(svc_prop))
          }
          flush_subactions
          Wakame.log.debug("#{self.class}: DG level next")
        }
      end

    end
  end
end
