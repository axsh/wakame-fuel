

class Wakame::Command::LaunchCluster
  include Wakame::Command

  command_name='launch_cluster'

  def run(rule)
    rule.trigger_action(Wakame::Actions::LaunchCluster.new)
  end
end
