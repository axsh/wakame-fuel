
class Wakame::Command::PropagateService
  include Wakame::Command

  #command_name='launch_cluster'

  def parse(args)
    @resname = args.shift
    @num = args.shift unless args.empty?
  end

  def run(rule)
    prop = nil
    prop = rule.service_cluster.properties[@resname.to_s]
    if prop.nil?
      raise "UnknownProperty: #{@resname}" 
    end

    @num ||= 1

    rule.trigger_action(Wakame::Actions::PropagateInstances.new(prop, @num))
  end

end
