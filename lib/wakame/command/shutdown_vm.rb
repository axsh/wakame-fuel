
class Wakame::Command::ShutdownVm
  include Wakame::Command

  command_name 'shutdown_vm'

  def run(rule)
    registered_agents = rule.agent_monitor.registered_agents[@options["agent_id"]]
    if !registered_agents.services.nil?
      if !@options["force"].nil?
        registered_agents.services.each{|id, svc_inst|
	  rule.trigger_action(Wakame::Actions::StopService.new(svc_inst))
	}
      else
        raise "Service instances Launched"
      end
    end
    rule.trigger_action(Wakame::Actions::ShutdownVM.new(registered_agents))
  end
end
