
class Wakame::Command::PropagateService
  include Wakame::Command

  #command_name='launch_cluster'

  def parse(args)
    @resource
  end

  def run(rule)
    prop = nil
    prop = rule.service_cluster.properties[@options["service"]]
    if prop.nil?
      raise "UnknownProperty: #{@options["service"]}" 
    end

    @num = nil
    @num = @options["num"] || 1

    unless /^(\d){1,32}$/ =~ @num.to_s
      raise "The number is not appropriate: #{@num}"
    end

    instance = rule.master.service_cluster.dump_status[:properties][@options["service"]]
    if @num.to_i > (instance[:max_instances].to_i - instance[:instances].count.to_i)
      raise "The number is not appropriate: #{@num}"
    end

    EM.barrier {
      @num.to_i.times {
        rule.service_cluster.propagate(prop)
      }
    }
    rule.trigger_action(Wakame::Rule::PropagateInstancesAction.new(prop))
  end
end
