
class Wakame::Command::PropagateService
  include Wakame::Command
  include Wakame

  command_name='propagate_service'

  def run(trigger)
    refsvc = Service::ServiceInstance.find(@options["service_id"]) || raise("Unknown ServiceInstance ID: #{@options["service_id"]}")

    cloud_host_id = @options["cloud_host_id"]
    if cloud_host_id.nil? || cloud_host_id == ""
      cloud_host_id = nil
    else
      cloud_host = Service::CloudHost.find(cloud_host_id) || raise("Specified cloud host was not found: #{cloud_host_id}")
      raise "Same resouce type is already assigned: #{refsvc.resource.class} on #{cloud_host_id}" if cloud_host.has_resource_type?(refsvc.resource)
    end

    num = @options["number"] || 1
    raise "Invalid format of number: #{num}" unless /^(\d+)$/ =~ num.to_s
    num = num.to_i

    if num < 1 || refsvc.resource.max_instances < trigger.cluster.instance_count(refsvc.resource) + num
      raise "The number must be between 1 and #{refsvc.resource.max_instances - trigger.cluster.instance_count(refsvc.resource)} (max limit: #{refsvc.resource.max_instances})"
    end

    num.times {
      trigger.trigger_action(Wakame::Actions::PropagateService.new(refsvc, cloud_host_id))
    }
  end
end
