
class Wakame::Command::DeployConfig
  include Wakame::Command
  include Wakame::Service

  command_name 'deploy_config'

  def run
    cluster.each_instance.map { |svc_inst|
      next if svc_inst.cloud_host_id.nil?
      Wakame.log.debug(svc_inst)
      trigger_action(Wakame::Actions::DeployConfig.new(svc_inst))
    }
  end

end
