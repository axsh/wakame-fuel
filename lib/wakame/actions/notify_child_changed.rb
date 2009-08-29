module Wakame
  module Actions
    class NotifyChildChanged < Action
      def initialize(svc)
        @child_svc = svc
      end
      
      def run
        parents = []
        StatusDB.barrier {
          parents = @child_svc.parent_instances
        }

        acquire_lock { |lst|
          lst << parents.map{|c| c.resource.id }.uniq
        }
        
        Wakame.log.debug("#{self.class}: Parent nodes for #{@svc.resource.class}: " + parents.map{|c| c.resource.class }.uniq.inspect )

        parents.each { |svc|
          if svc.status != Service::STATUS_ONLINE
            next
          end

          trigger_action {
            svc.resource.on_child_changed(svc, self)
          }
        }
        flush_subactions

      end
    end
  end
end