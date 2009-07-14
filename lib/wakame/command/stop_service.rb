class Wakame::Command::StopService
  include Wakame::Command

  command_name='stop_service'

  def run(rule)
      unless @options["instances"].nil?
        svc_inst = rule.service_cluster.instances
        rule.trigger_action(Wakame::Actions::StopService.new(svc_inst[@options["instances"]]))
      end
      levels = rule.service_cluster.dg.levels
      levels.reverse.each { |lv|
        lv.each { |svc_prop|
	if svc_prop.class.to_s == @options["service"].to_s
          rule.service_cluster.each_instance(svc_prop.class) { |svc_inst|
            rule.trigger_action(Wakame::Actions::StopService.new(svc_inst))
          }
	end
        }
      }
  end
end
