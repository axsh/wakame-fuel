
require 'wakame/actions/util'

module Wakame
  module Actions
    class MigrateService < Action
      include Actions::Util

      def initialize(service_instance, dest_agent=nil)
        @service_instance = service_instance
        @destination_agent = dest_agent
      end

      def run
        raise CancelActionError if @service_instance.status == Service::STATUS_MIGRATING

        EM.barrier {
          @service_instance.update_status(Service::STATUS_MIGRATING)
        }
        prop = @service_instance.property
        if prop.duplicable
          clone_service(prop)
          flush_subactions
          trigger_action(StopService.new(@service_instance))
        else
          
          trigger_action(StopService.new(@service_instance))
          flush_subactions
          clone_service(prop)
        end
        flush_subactions
      end

      private
      def clone_service(resource)
        new_svc = nil
        EM.barrier {
          new_svc = service_cluster.propagate(resource, true)
        }

        agent = @destination_agent
        if agent.nil?
          EM.barrier {
            agent = arrange_agent(resource)
          }
          if agent.nil?
            inst_id = start_instance(master.attr[:ami_id], resource.vm_spec.current.attrs)
            agent = agent_monitor.registered_agents[inst_id]
          end
        end

        if !(agent && test_agent_candidate(resource, agent))
          raise "Found confiction(s) when the agent is assigned to sevice: #{resource} #{agent} "
        end

        EM.barrier {
          new_svc.bind_agent(agent)
        }

        trigger_action(StartService.new(new_svc))
        new_svc
      end
    end
  end
end
