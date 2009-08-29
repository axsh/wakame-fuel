module Wakame
  module Actions
    class NotifyParentChanged < Action
      def initialize(svc)
        @parent_svc = svc
      end
      
      def run
        children = []
        StatusDB.barrier {
          children = @parent_svc.child_instances
        }

        acquire_lock { |lst|
          lst << children.map{|c| c.resource.id }.uniq
        }
        
        Wakame.log.debug("#{self.class}: Child nodes for #{@svc.resource.class}: " + children.map{|c| c.resource.class }.uniq.inspect )

        children.each { |svc|
          if svc.status != Service::STATUS_ONLINE
            next
          end

          trigger_action {
            svc.resource.on_parent_changed(svc, self)
          }
        }
        flush_subactions

      end
    end
  end
end
