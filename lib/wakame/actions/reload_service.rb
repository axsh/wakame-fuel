module Wakame
  module Actions
    class ReloadService < Action
      def initialize(service_instance)
        @service_instance = service_instance
      end

      def run
        raise "Agent is not bound on this service : #{@service_instance}" if @service_instance.agent.nil?
        raise "The assigned agent for the service instance #{@service_instance.instance_id} is not online."  unless @service_instance.agent.status == Service::Agent::STATUS_ONLINE

        # Skip to act when the service is having below status.
        #if @service_instance.status == Service::STATUS_STARTING || @service_instance.status == Service::STATUS_ONLINE
        #  raise "Canceled as the service is being or already ONLINE: #{@service_instance.property}"
        #end

	@service_instance.resource.reload(@service_instance, self)
      end
    end
  end
end
