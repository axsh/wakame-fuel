

class Wakame::Command::LaunchCluster
  include Wakame::Command

  command_name='launch_cluster'

  def parse(args)
  end

  def run(rule)
    rule.trigger_action(Wakame::Rule::ClusterLaunchAction.new)
  end

end
