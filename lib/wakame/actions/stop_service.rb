module Wakame
  module Actions
    class StopService < Action
      def initialize(service_instance)
        @acquire_lock = true
        @service_instance = service_instance
      end


      def run
        raise "Agent is not bound on this service : #{@service_instance}" if @service_instance.property.require_agent && @service_instance.agent.nil?
        
        # Skip to act when the service is having below status.
        if @service_instance.status == Service::STATUS_STOPPING || @service_instance.status == Service::STATUS_OFFLINE
          raise CancelActionError, "Canceled as the service is being or already OFFLINE: #{@service_instance.property}"
        end

        EM.barrier {
          @service_instance.update_status(Service::STATUS_STOPPING)
        }
        
        EM.barrier {
          Wakame.log.debug("Child nodes: #{@service_instance.property.class}: " + service_cluster.dg.children(@service_instance.property.class).inspect)
          service_cluster.dg.children(@service_instance.property.class).each { |svc_prop|
            trigger_action(CallChildChangeAction.new(svc_prop))
          }
        }

        flush_subactions()

        if @service_instance.status == Service::STATUS_ONLINE
          @service_instance.property.stop(@service_instance, self)
        else
        end
        
        EM.barrier {
          service_cluster.destroy(@service_instance.instance_id)
        }
      end

      def on_failed
        EM.barrier {
          @service_instance.update_status(Service::STATUS_FAIL)
        }
      end

    end
  end
end
