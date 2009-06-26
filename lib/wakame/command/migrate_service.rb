
class Wakame::Command::MigrateService
  include Wakame::Command

  #command_name='launch_cluster'

  def parse(args)
    @svc_id = args.shift
  end

  def run(rule)
    svc = nil
    svc = rule.service_cluster.instances[@svc_id]
    if svc.nil?
      raise "Unknown Service ID: #{@svc_id}" 
    end

    rule.trigger_action(Wakame::Actions::MigrateService.new(svc))
  end

end
