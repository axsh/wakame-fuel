

class Wakame::Command::ShutdownCluster
  include Wakame::Command

  command_name='shutdown_cluster'

  def run(rule)
    rule.trigger_action(Wakame::Rule::ClusterShutdownAction.new)
  end
end
