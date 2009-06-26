
require 'wakame/actions/util'

module Wakame
  module Actions
    class PropagateInstances < Action
      include Actions::Util

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

        svc_to_start.each { |svc|
          if svc.property.require_agent
            # Try to arrange agent from existing agent pool.
            if svc.agent.nil?
              EM.barrier {
                arrange_agent(svc)
              }
            end
            
            # If the agent pool is empty, will start a new VM slice.
            if svc.agent.nil?
              inst_id = start_instance(master.attr[:ami_id], @svc_prop.vm_spec.current.attrs)
              EM.barrier {
                arrange_agent(svc, inst_id)
              }
            end
            
            if svc.agent.nil?
              Wakame.log.error("Failed to arrange the agent #{svc.instance_id} (#{svc.property.class})")
              raise "Failed to arrange the agent #{@svc_prop.class}"
            end
          end

          trigger_action(StartService.new(svc))
        }
        flush_subactions
      end

      private
      # Arrange an agent for the paticular service instance which does not have agent.
      def arrange_agent(svc, vm_inst_id=nil)
        agent = nil
        if vm_inst_id
          agent = agent_monitor.registered_agents[vm_inst_id]
          raise "Cound not find the specified VM instance \"#{vm_inst_id}\"" if agent.nil?
          raise "Same service is running" if agent.has_service_type? @svc_prop.class
        else
          agent_monitor.each_online { |ag|
            Wakame.log.debug "has_service_type?(#{@svc_prop.class}): #{ag.has_service_type?(@svc_prop.class)}"
            if test_agent_candidate(@svc_prop, ag)
              agent = ag
              break
            end
          }
        end
        if agent
          svc.bind_agent(agent)
        end
      end

    end
  end
end
