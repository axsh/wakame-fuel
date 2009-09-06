module Wakame
  module Actions
    class PropagateService < Action

      def initialize(svc, host_id=nil)
        raise ArgumentError unless svc.is_a?(Wakame::Service::ServiceInstance)
        @svc = svc
        @host_id = host_id
      end


      def run
        acquire_lock { |ary|
          ary << @svc.resource.class.to_s
        }

        newsvc = nil
        StatusDB.barrier {
          newsvc = cluster.propagate_service(@svc.id, @host_id)
        }
        trigger_action(StartService.new(newsvc))
        flush_subactions
      end

    end
  end
end
