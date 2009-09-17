module Wakame
  module Actions
    class StopService < Action
      def initialize(svc, do_terminate=true)
        raise ArgumentError unless svc.is_a?(Service::ServiceInstance)
        @svc = svc
        @do_terminate = do_terminate
      end


      def run
        # Skip to act when the service is having below status.
        if @svc.status == Service::STATUS_STOPPING || @svc.status == Service::STATUS_OFFLINE
          Wakame.log.info("Ignore to stop the service as is being or already OFFLINE: #{@svc.resource.class}")
          return
        end

        acquire_lock { |lst|
          lst << @svc.resource.class.to_s
        }

        if @svc.resource.require_agent && !@svc.cloud_host.mapped?
          raise "Agent is not bound on this service : #{@svc}"
        end

        StatusDB.barrier {
          @svc.update_status(Service::STATUS_STOPPING)
        }
        
        trigger_action(NotifyChildChanged.new(@svc))
        flush_subactions

        @svc.resource.stop(@svc, self)

        if @do_terminate
          if @svc.resource.require_agent
            StatusDB.barrier {
              @svc.update_status(Service::STATUS_QUITTING)
            }
            @svc.resource.on_quit_agent(@svc, self)
          end

          StatusDB.barrier {
            @svc.update_status(Service::STATUS_TERMINATE)
            cluster.destroy(@svc.id)
          }
        end
      end

      def on_failed
        StatusDB.barrier {
          @svc.update_status(Service::STATUS_FAIL)
        }
      end

    end
  end
end
