
class Wakame::Command::ReloadService
  include Wakame::Command

  command_name='reload_service'

  def run(rule)
    if !@options["service_name"].nil?
      levels = rule.service_cluster.dg.levels
      levels.reverse.each {|lv|
        lv.each { |svc_prop|
          if svc_prop.class.to_s == @options["service_name"].to_s
            rule.service_cluster.each_instance(svc_prop.class) { |svc_inst|
              rule.trigger_action(Wakame::Actions::ReloadService.new(svc_inst))
            }
          end
        }
      }
    end
  end
end
