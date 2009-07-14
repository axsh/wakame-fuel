
class Wakame::Command::MigrateService
  include Wakame::Command

  def run(rule)
    svc = nil
    svc = rule.service_cluster.instances[@options["service_id"]]
    if svc.nil?
      raise "Unknown Service ID: #{@options["service_id"]}" 
    end

    # Optional destination agent 
    agent = nil
    if @options["agent_id"]
      agent = rule.agent_monitor.agent(@options["agent_id"])
      if agent.nil?
        raise "Unknown Agent ID: #{@options["agent_id"]}" 
      end
    end

    rule.trigger_action(Wakame::Actions::MigrateService.new(svc, agent))
  end

end
