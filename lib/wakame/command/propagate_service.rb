
class Wakame::Command::PropagateService
  include Wakame::Command

  #command_name='launch_cluster'

  def parse(args)
    @resource
  end

  def run(rule)
    prop = nil
    prop = master.service_cluster.properties[]
    if prop.nil?
      raise "UnknownProperty: #{prop_name}" 
    end

    EM.barrier {
      rule.service_cluster.propagete
    }
    rule.trigger_action(Wakame::Rule::PropagateInstancesAction.new)
  end

end
