class Wakame::Command::StopService
  include Wakame::Command

  command_name='stop_service'

  def run(rule)
      svc_inst = rule.service_cluster.instances
      rule.trigger_action(Wakame::Actions::StopService.new(svc_inst[@options["instances"]]))
  end
end
