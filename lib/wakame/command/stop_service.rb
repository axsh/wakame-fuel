class Wakame::Command::StopService
  include Wakame::Command

  command_name='stop_service'

  def run(rule)

    if !@options["service_id"].nil?
      svc_inst = rule.service_cluster.instances
      rule.trigger_action(Wakame::Actions::StopService.new(svc_inst[@options["service_id"]]))
    end
    if !@options["service_name"].nil?
      levels = rule.service_cluster.dg.levels
      levels.reverse.each {|lv|
       lv.each { |svc_prop|
         if svc_prop.class.to_s == @options["service_name"].to_s
           rule.service_cluster.each_instance(svc_prop.class) { |svc_inst|
             rule.trigger_action(Wakame::Actions::StopService.new(svc_inst))
           }
         end
       }
     }
    end
    if !@options["agent_id"].nil?
      registered_agents = rule.agent_monitor.registered_agents[@options["agent_id"]]
      registered_agents.services.each{|id, svc_inst|
        rule.trigger_action(Wakame::Actions::StopService.new(svc_inst))
      }
    end
  end
end
