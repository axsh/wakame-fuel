module Wakame
  module Actions
    class UnfreezeCluster < Action

      def run
        acquire_lock { |lst|
          lst << cluster.resources.keys.map {|resid| ServiceResource.find(resid).class.to_s  }
        }
        StatusDB.barrier {
          cluster.update_freeze_status(Service::ServiceCluster::STATUS_UNFROZEN)
        }

      end
    end
  end
end
