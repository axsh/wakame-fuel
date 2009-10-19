
module Wakame
  module Actions
    class StartService < Action
      def initialize(service_instance)
        @service_instance = service_instance
      end

      def run
        acquire_lock(@service_instance.resource.class.to_s)
        @service_instance.reload

        # Skip to act when the service is having below status.
        if @service_instance.status == Service::STATUS_RUNNING && @service_instance.monitor_status == Service::STATUS_ONLINE
          Wakame.log.info("Ignore to start the service as is being or already Online: #{@service_instance.resource.class}")
          return
        end

        if @service_instance.resource.require_agent
          raise "The service is not bound cloud host object: #{@service_instance.id}" if @service_instance.cloud_host_id.nil?

          unless @service_instance.cloud_host.mapped?
            acquire_lock(Models::AgentPool.class.to_s)
            
            # Try to arrange agent from existing agent pool.
            StatusDB.barrier {
              next if Models::AgentPool.instance.group_active.empty?
              agent2host = cluster.agents.invert
              
              #Service::AgentPool.instance.group_active.keys.each { |agent_id|
              Models::AgentPool.instance.group_active.each { |agent_id|
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
          
          StatusDB.barrier {
            @service_instance.update_status(Service::STATUS_STARTING)
          }
          
          # Setup monitorring
          @service_instance.cloud_host.monitors.each { |path, conf|
            Wakame.log.debug("#{self.class}: Sending monitorring setting to #{@service_instance.cloud_host.agent_id}: #{path} => #{conf.inspect}")
            actor_request(@service_instance.cloud_host.agent_id, '/monitor/reload', path, conf).request.wait
          }
          
          @service_instance.resource.on_enter_agent(@service_instance, self)
        end
        

        StatusDB.barrier {
          @service_instance.update_status(Service::STATUS_STARTING)
        }
        
        if @service_instance.resource.require_agent
          trigger_action(DeployConfig.new(@service_instance))
          flush_subactions
        end

        @service_instance.reload
        Wakame.log.debug("#{@service_instance.resource.class}: svc.monitor_status == Wakame::Service::STATUS_ONLINE => #{@service_instance.monitor_status == Wakame::Service::STATUS_ONLINE}")
        if @service_instance.monitor_status != Wakame::Service::STATUS_ONLINE
          @service_instance.resource.start(@service_instance, self)
        end

        StatusDB.barrier {
          @service_instance.update_status(Service::STATUS_RUNNING)
        }
        
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
