module Wakame
  module Actions
    class PropagateResource < Action

      def initialize(resource, host_id)
        raise ArgumentError unless resource.is_a?(Wakame::Service::Resource)
        @resource = resource
        @host_id = host_id
      end

      def run
        acquire_lock { |ary|
          ary << @resource.class.to_s
        }

        newsvc=nil
        StatusDB.barrier {
          newsvc = service_cluster.propagate_resource(@resource, @host_id)
        }

        trigger_action(StartService.new(newsvc))
        flush_subactions
      end

    end
  end
end
