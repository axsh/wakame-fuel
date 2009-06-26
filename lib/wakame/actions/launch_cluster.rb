module Wakame
  module Actions
    class LaunchCluster < Action
      def initialize
        @acquire_lock = true
      end

      def run
        if service_cluster.status == Service::ServiceCluster::STATUS_ONLINE
          Wakame.log.info("The service cluster is up & running already")
          raise CancelActionError
        end

        EM.barrier {
          service_cluster.launch
        }

        Wakame.log.debug("#{self.class}: Resource Launch Order: " + service_cluster.dg.levels.collect {|lv| '['+ lv.collect{|prop| "#{prop.class}" }.join(', ') + ']' }.join(', '))

        service_cluster.dg.levels.each { |lv|
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
