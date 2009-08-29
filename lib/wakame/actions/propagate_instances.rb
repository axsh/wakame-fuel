module Wakame
  module Actions
    class PropagateInstances < Action

      def initialize(resource, propagate_num=0)
        raise ArgumentError unless resource.is_a?(Wakame::Service::Resource)
        @resource = resource
        @propagate_num = propagate_num
      end

      def run
        svc_to_start = []

        StatusDB.barrier {
          @propagate_num.times {
            service_cluster.propagate(@resource)
          }

          # First, look for the service instances which are already created in the cluster. Then they will be scheduled to start the services later.
          online_svc = []
          service_cluster.each_instance(@resource.class) { |svc|
            if svc.status == Service::STATUS_ONLINE || svc.status == Service::STATUS_STARTING
              online_svc << svc
            else
              svc_to_start << svc
            end
          }

          # The list is empty means that this action is called to propagate a new service instance instead of just starting scheduled instances.
          svc_count = service_cluster.instance_count(@resource)
          if svc_count > online_svc.size + svc_to_start.size
            Wakame.log.debug("#{self.class}: @resource.instance_count - online_svc.size=#{svc_count - online_svc.size}")
            (svc_count - (online_svc.size + svc_to_start.size)).times {
              svc_to_start << service_cluster.propagate(@resource.class)
            }
          end
        }

        acquire_lock { |ary|
          svc_to_start.each { |svc|
            ary << svc.resource.id
          }
        }

        svc_to_start.each { |svc|
          target_agent = nil
          if svc.resource.require_agent && !svc.host.mapped?
            # Try to arrange agent from existing agent pool.
            StatusDB.barrier {
              AgentPool.instance.group_active.each { |agent_id|
                agent = Agent.find(agent_id)
                if agent.has_resource_type?(svc.resource) # && svc.resource.vm_spec.current.satisfy?(agent.vm_attrs)
                  target_agent = agent
                  break
                end
              }
            }
            
            unless target_agent.nil?
              Wakame.log.debug("#{self.class}: arranged agent for #{svc.resource.class}: #{target_agent.id}")
            end
          end
          
          trigger_action(StartService.new(svc, target_agent))
        }
        flush_subactions
      end
      
    end
  end
end
