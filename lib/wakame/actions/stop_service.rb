module Wakame
  module Actions
    class StopService < Action
      def initialize(service_instance)
        @service_instance = service_instance
      end


      def run
        acquire_lock { |lst|
          lst << @service_instance.resource.id
        }
        if @service_instance.resource.require_agent && @service_instance.host.mapped?
          raise "Agent is not bound on this service : #{@service_instance}"
        end
        
        # Skip to act when the service is having below status.
        if @service_instance.status == Service::STATUS_STOPPING || @service_instance.status == Service::STATUS_OFFLINE
          raise CancelActionError, "Canceled as the service is being or already OFFLINE: #{@service_instance.resource}"
        end

        StatusDB.barrier {
          @service_instance.update_status(Service::STATUS_STOPPING)
        }
        
        trigger_action(NotifyChildChanged.new(@service_instance))
        flush_subactions

        @service_instance.resource.stop(@service_instance, self)
        
        StatusDB.barrier {
          service_cluster.destroy(@service_instance.id)
        }
      end

      def on_failed
        StatusDB.barrier {
          @service_instance.update_status(Service::STATUS_FAIL)
        }
      end

    end
  end
end
