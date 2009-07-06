
require 'erb'

class Wakame::Command::Status
  include Wakame::Command

  def run(rule)
   EM.barrier {
      master = rule.master
      
      @service_cluster = master.service_cluster.dump_status
      @agent_monitor = master.agent_monitor.dump_status
      res = {
        :service_cluster => @service_cluster,
        :agent_monitor => @agent_monitor
      }
      res
    }

  end
end
