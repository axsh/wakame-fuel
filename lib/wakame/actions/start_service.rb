
require 'wakame/rule'

module Wakame
  module Actions
    class StartService < Action
      def initialize(service_instance, target_agent=nil)
        @service_instance = service_instance
        @target_agent = target_agent
      end

      def run
        if @service_instance.resource.require_agent

          if @service_instance.agent.nil?
            # Start new VM when the target agent is nil.
            if @target_agent.nil?
              inst_id_key = "new_inst_id_" + Wakame::Util.gen_id
              trigger_action(LaunchVM.new(inst_id_key))
              flush_subactions
              
              EM.barrier {
                @target_agent = agent_monitor.registered_agents[notes[inst_id_key]]
                raise "Cound not find the specified VM instance \"#{notes[inst_id_key]}\"" if @target_agent.nil?
                raise "Same service is running" if @target_agent.has_service_type? @service_instance.resource.class
              }
            end

            EM.barrier {
              @service_instance.bind_agent(@target_agent)
            }
          end


          raise "Agent is not bound on this service : #{@service_instance}" if @service_instance.agent.nil?
          raise "The assigned agent for the service instance #{@service_instance.instance_id} is not online."  unless @service_instance.agent.status == Service::Agent::STATUS_ONLINE
        end
        
        # Skip to act when the service is having below status.
        if @service_instance.status == Service::STATUS_STARTING || @service_instance.status == Service::STATUS_ONLINE
          raise "Canceled as the service is being or already ONLINE: #{@service_instance.resource}"
        end
        EM.barrier {
          @service_instance.update_status(Service::STATUS_STARTING)
        }
        
        if @service_instance.resource.require_agent
          Rule::BasicActionSet.deploy_configuration(@service_instance)
        end

        @service_instance.resource.start(@service_instance, self)
        
        EM.barrier {
          Wakame.log.debug("Child nodes: #{@service_instance.resource.class}: " + service_cluster.dg.children(@service_instance.property.class).inspect)
          service_cluster.dg.children(@service_instance.resource.class).each { |svc_res|
            Wakame.log.debug("Spreading DG child changed: #{@service_instance.resource.class} -> #{svc_res.class}")
            trigger_action(Actions::CallChildChangeAction.new(svc_res))
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
