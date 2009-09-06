
class Wakame::Command::PropagateResource
  include Wakame::Command
  include Wakame

  command_name='propagate_resource'

  def run(trigger)
    resname = @options["resource"]

    resobj = Service::Resource.find(Service::Resource.id(resname))
    if resobj.nil?
      raise "Unknown Resource: #{resname}" 
    end

    host_id = @options["host_id"]
    if host_id.nil?
      host = trigger.cluster.add_host { |h|
        if @options["vm_attr"].is_a? Hash
          h.vm_attr = @options["vm_attr"]
        end
      }
    else
      host = Service::Host.find(host_id) || raise("Specified host was not found: #{host_id}")
      raise "Same resouce type is already assigned: #{resobj.class} on #{host_id}" if host.has_resource_type?(resobj)
    end
    

    num = @options["number"] || 1
    raise "Invalid format of number: #{num}" unless /^(\d+)$/ =~ num.to_s
    num = num.to_i

    if num < 1 || resobj.max_instances < trigger.cluster.instance_count(resobj) + num
      raise "The number must be between 1 and #{resobj.max_instances - trigger.cluster.instance_count(resobj)} (max limit: #{resobj.max_instances})"
    end

    num.times {
      trigger.trigger_action(Wakame::Actions::PropagateResource.new(resobj, host.id))
    }

  end
end
