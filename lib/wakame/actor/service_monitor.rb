
class Wakame::Actor::ServiceMonitor
  include Wakame::Actor

  expose '/service_monitor/register', :register
  def register(svc_id, cmdstr)
    EM.barrier {
      svcmon = agent.monitor_registry.find_monitor('/service')
      svcmon.register(svc_id, cmdstr)
    }
  end

  expose '/service_monitor/unregister', :unregister
  def unregister(svc_id)
    EM.barrier {
      svcmon = agent.monitor_registry.find_monitor('/service')
      svcmon.unregister(svc_id)
    }
  end

end
