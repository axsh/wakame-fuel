
require 'wakame/rule'

module Wakame
  module Actions
    class StartService < Action
      def initialize(service_instance, target_agent=nil)
        @service_instance = service_instance
        @target_agent = target_agent
      end

      def run
        acquire_lock { |lst|
          lst << @service_instance.resource.id
        }

        if @service_instance.resource.require_agent

          if !@service_instance.host.mapped?
            # Start new VM when the target agent is nil.
            if @target_agent.nil?
              inst_id_key = "new_inst_id_" + Wakame::Util.gen_id
              trigger_action(LaunchVM.new(inst_id_key))
              flush_subactions
              
              StatusDB.barrier {
                @target_agent = Agent.find(notes[inst_id_key])
                raise "Cound not find the specified VM instance \"#{notes[inst_id_key]}\"" if @target_agent.nil?
              }
            end

            StatusDB.barrier {
              @service_instance.host.map_agent(@target_agent)
            }
          end


          raise "Agent is not bound on this service : #{@service_instance}" unless @service_instance.host.mapped?
          raise "The assigned agent for the service instance #{@service_instance.id} is not online."  unless @service_instance.host.status == Service::Agent::STATUS_ONLINE
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
