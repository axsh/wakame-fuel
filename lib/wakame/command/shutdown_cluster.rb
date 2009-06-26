

class Wakame::Command::ShutdownCluster
  include Wakame::Command

  command_name='shutdown_cluster'

  def parse(args)
  end

  def run(rule)
    rule.trigger_action(Wakame::Actions::ShutdownCluster.new)
  end

end
