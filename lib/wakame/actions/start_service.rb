
require 'wakame/rule'

module Wakame
  module Actions
    class StartService < Action
      def initialize(service_instance)
        @acquire_lock = true
        @service_instance = service_instance
      end

      def run
        if @service_instance.property.require_agent
          raise "Agent is not bound on this service : #{@service_instance}" if @service_instance.agent.nil?
          raise "The assigned agent for the service instance #{@service_instance.instance_id} is not online."  unless @service_instance.agent.status == Service::Agent::STATUS_ONLINE
        end
        
        # Skip to act when the service is having below status.
        if @service_instance.status == Service::STATUS_STARTING || @service_instance.status == Service::STATUS_ONLINE
          raise "Canceled as the service is being or already ONLINE: #{@service_instance.property}"
        end
        EM.barrier {
          @service_instance.update_status(Service::STATUS_STARTING)
        }
        
        if @service_instance.property.require_agent
          Rule::BasicActionSet.deploy_configuration(@service_instance)
        end

        @service_instance.resource.start(@service_instance, self)
        
        EM.barrier {
          Wakame.log.debug("Child nodes: #{@service_instance.property.class}: " + service_cluster.dg.children(@service_instance.property.class).inspect)
          service_cluster.dg.children(@service_instance.property.class).each { |svc_prop|
            Wakame.log.debug("Spreading DG child changed: #{@service_instance.property.class} -> #{svc_prop.class}")
            trigger_action(Actions::CallChildChangeAction.new(svc_prop))
          }
        }

      end

      def on_failed
        EM.barrier {
          @service_instance.update_status(Service::STATUS_FAIL)
        }
      end
    end

    class CallChildChangeAction < Action
      def initialize(resource)
        @resource = resource
        #@parent_instance = parent_instance
      end
      
      def run
        Wakame.log.debug("CallChildChangeAction: run: #{@resource.class}")
        service_cluster.each_instance(@resource.class) { |svc_inst|
          next if svc_inst.status != Service::STATUS_ONLINE
          @resource.on_parent_changed(svc_inst, self)
        }
      end
    end
  end
end
