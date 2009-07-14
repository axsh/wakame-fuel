module Wakame
  module Actions
    class PropagateInstances < Action

      def initialize(svc_prop, propagate_num=0)
        raise ArgumentError unless svc_prop.is_a?(Wakame::Service::Resource)
        @svc_prop = svc_prop
        @propagate_num = propagate_num
      end

      def run
        svc_to_start = []

        EM.barrier {
          @propagate_num.times {
            service_cluster.propagate(@svc_prop)
          }

          # First, look for the service instances which are already created in the cluster. Then they will be scheduled to start the services later.
          online_svc = []
          service_cluster.each_instance(@svc_prop.class) { |svc_inst|
            if svc_inst.status == Service::STATUS_ONLINE || svc_inst.status == Service::STATUS_STARTING
              online_svc << svc_inst
            else
              svc_to_start << svc_inst
            end
          }

          # The list is empty means that this action is called to propagate a new service instance instead of just starting scheduled instances.
          svc_count = service_cluster.instance_count(@svc_prop)
          if svc_count > online_svc.size + svc_to_start.size
            Wakame.log.debug("#{self.class}: @svc_prop.instance_count - online_svc.size=#{svc_count - online_svc.size}")
            (svc_count - (online_svc.size + svc_to_start.size)).times {
              svc_to_start << service_cluster.propagate(@svc_prop.class)
            }
          end
        }

        acquire_lock { |ary|
          svc_to_start.each { |svc|
            ary << svc.resource.class
          }
        }

        svc_to_start.each { |svc|
          target_agent = nil
          if svc.property.require_agent
            # Try to arrange agent from existing agent pool.
            if svc.agent.nil?
              EM.barrier {
                agent_monitor.each_online { |ag|
                  if !ag.has_service_type?(@svc_prop.class) && @svc_prop.vm_spec.current.satisfy?(ag)
                    target_agent = ag
                    break
                  end
                }
              }
            end

            Wakame.log.debug("#{self.class}: arranged agent for #{svc.resource.class}: #{target_agent ? target_agent.agent_id : nil}")
          end

          trigger_action(StartService.new(svc, target_agent))
        }
        flush_subactions
      end

    end
  end
end
