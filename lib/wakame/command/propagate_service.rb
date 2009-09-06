
class Wakame::Command::PropagateService
  include Wakame::Command
  include Wakame

  command_name='propagate_service'

  def run(trigger)
    refsvc = Service::ServiceInstance.find(@options["service_id"]) || raise("Unknown ServiceInstance: #{@options["service_id"]}")

    host_id = @options["host_id"]
    unless host_id.nil?
      host = Service::Host.find(host_id) || raise("Specified host was not found: #{host_id}")
      raise "Same resouce type is already assigned: #{refsvc.resource.class} on #{host_id}" if host.has_resource_type?(refsvc.resource)
    end

    num = @options["number"] || 1
    raise "Invalid format of number: #{num}" unless /^(\d+)$/ =~ num.to_s
    num = num.to_i

    if num < 1 || refsvc.resource.max_instances < trigger.cluster.instance_count(refsvc.resource) + num
      raise "The number must be between 1 and #{refsvc.resource.max_instances - trigger.cluster.instance_count(refsvc.resource)} (max limit: #{refsvc.resource.max_instances})"
    end

    num.times {
      trigger.trigger_action(Wakame::Actions::PropagateService.new(refsvc))
    }
  end
end
