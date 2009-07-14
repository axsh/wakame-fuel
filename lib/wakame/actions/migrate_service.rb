
module Wakame
  module Actions
    class MigrateService < Action
      def initialize(service_instance, dest_agent=nil)
        @service_instance = service_instance
        @destination_agent = dest_agent
      end

      def run
        acquire_lock { |list|
          list << @service_instance.resource.class
        }

        raise CancelActionError if @service_instance.status == Service::STATUS_MIGRATING

        EM.barrier {
          @service_instance.update_status(Service::STATUS_MIGRATING)
        }
        prop = @service_instance.resource
        if prop.duplicable
          clone_service(prop)
          flush_subactions
          trigger_action(StopService.new(@service_instance))
        else
          
          trigger_action(StopService.new(@service_instance))
          flush_subactions
          clone_service(prop)
        end
        flush_subactions
      end

      private
      def clone_service(resource)
        new_svc = nil
        EM.barrier {
          new_svc = service_cluster.propagate(resource, true)
        }

        trigger_action(StartService.new(new_svc, @destination_agent))
        new_svc
      end
    end
  end
end
