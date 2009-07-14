
class Wakame::Actor::ServiceMonitor
  include Wakame::Actor

  expose '/service_monitor/register', :register
  def register(svc_id, type, *args)
    EM.barrier {
      svcmon = agent.monitor_registry.find_monitor('/service')
      svcmon.register(svc_id, type, *args)
    }
    self.return_value = check_status(svc_id)
  end

  expose '/service_monitor/unregister', :unregister
  def unregister(svc_id)
    EM.barrier {
      svcmon = agent.monitor_registry.find_monitor('/service')
      svcmon.unregister(svc_id)
    }
  end

  # Immediate status check for the specified Service ID.
  def check_status(svc_id)
    self.return_value = EM.barrier {
      svcmon = agent.monitor_registry.find_monitor('/service')
      svcmon.check_status(svc_id)
    }
    self.return_value
  end

end
