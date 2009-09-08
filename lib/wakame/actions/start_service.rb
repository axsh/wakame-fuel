
require 'wakame/rule'

module Wakame
  module Actions
    class StartService < Action
      def initialize(service_instance)
        @service_instance = service_instance
      end

      def run
        acquire_lock { |lst|
          lst << @service_instance.resource.class.to_s
        }

        if @service_instance.resource.require_agent
          unless @service_instance.cloud_host.mapped?
            acquire_lock { |lst|
              lst << Service::AgentPool.class.to_s
            }
            
            # Try to arrange agent from existing agent pool.
            StatusDB.barrier {
              break if Service::AgentPool.instance.group_active.empty?
              agent2host = cluster.agents.invert
              
              Service::AgentPool.instance.group_active.keys.each { |agent_id|
                agent = Service::Agent.find(agent_id)
                if !agent.has_resource_type?(@service_instance.resource) &&
                    agent2host[agent_id].nil? && # This agent is not mapped to any cloud hosts.
                    @service_instance.cloud_host.vm_spec.satisfy?(agent.vm_attr)
                  
                  @service_instance.cloud_host.map_agent(agent)
                  break
                end
              }
            }
            
            # Start new VM when the target agent is still nil.
            unless @service_instance.cloud_host.mapped?
              inst_id_key = "new_inst_id_" + Wakame::Util.gen_id
              trigger_action(LaunchVM.new(inst_id_key, @service_instance.cloud_host.vm_spec))
              flush_subactions
              
              StatusDB.barrier {
                agent = Service::Agent.find(notes[inst_id_key])
                raise "Cound not find the specified VM instance \"#{notes[inst_id_key]}\"" if agent.nil?
                @service_instance.cloud_host.map_agent(agent)
              }
            end
            
            raise "Could not find the agent to be assigned to : #{@service_instance.resource.class}" unless @service_instance.cloud_host.mapped?
          end
          
          raise "The assigned agent \"#{@service_instance.cloud_host.agent_id}\" for the service instance #{@service_instance.id} is not online."  unless @service_instance.cloud_host.status == Service::Agent::STATUS_ONLINE
        end
        
        # Skip to act when the service is having below status.
        if @service_instance.status == Service::STATUS_STARTING || @service_instance.status == Service::STATUS_ONLINE
          raise "Canceled as the service is being or already ONLINE: #{@service_instance.resource.class}"
        end

        StatusDB.barrier {
          @service_instance.update_status(Service::STATUS_STARTING)
        }
        
        if @service_instance.resource.require_agent
          trigger_action(DeployConfig.new(@service_instance))
          flush_subactions
        end

        @service_instance.resource.start(@service_instance, self)
        
        trigger_action(NotifyParentChanged.new(@service_instance))
        flush_subactions

      end

      def on_failed
        StatusDB.barrier {
          @service_instance.update_status(Service::STATUS_FAIL)
        }
      end
    end
  end
end
