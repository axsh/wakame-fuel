class Apache_LB < Wakame::Service::Resource
  include HttpServer
  
  property :listen_port, {:default=>80}
  property :listen_port_https, {:default=>443}
  
  def render_config(template)
    template.glob_basedir(%w(conf/envvars-lb init.d/apache2-lb)) { |d|
      template.cp(d)
    }
    template.glob_basedir(%w(conf/system-lb.conf conf/apache2.conf conf/vh/*.conf)) { |d|
      template.render(d)
    }
    template.chmod("init.d/apache2-lb", 0755)
  end

  def on_parent_changed(svc, action)
    action.trigger_action(Wakame::Actions::DeployConfig.new(svc))
    action.flush_subactions
    reload(svc, action)
  end

  def start(svc, action)
    cond = ConditionalWait.new { |cond|
      cond.wait_event(Wakame::Event::ServiceOnline) { |event|
        event.instance_id == svc.id
      }
    }

    request = action.actor_request(svc.cloud_host.agent_id,
                                   '/service_monitor/register', svc.id, :pidfile, '/var/run/apache2-lb.pid').request
    action.actor_request(svc.cloud_host.agent_id,
                         '/daemon/start', "apache_lb", 'init.d/apache2-lb'){ |req|
      req.wait
      Wakame.log.debug("#{self.class} process started")
    }

    cond.wait
  end
  
  def stop(svc, action)
    cond = ConditionalWait.new { |cond|
      cond.wait_event(Wakame::Event::ServiceOffline) { |event|
        event.instance_id == svc.id
      }
    }

    action.actor_request(svc.cloud_host.agent_id,
                         '/daemon/stop', 'apache_lb', 'init.d/apache2-lb'){ |req|
      req.wait
      Wakame.log.debug("#{self.class} process stopped")
    }

    cond.wait

    request = action.actor_request(svc.cloud_host.agent_id,
                                   '/service_monitor/unregister', svc.id ).request
  end

  def reload(svc, action)
    action.actor_request(svc.cloud_host.agent_id,
                         '/daemon/reload', "apache_lb", 'init.d/apache2-lb'){ |req|
      req.wait
      Wakame.log.debug("#{self.class} process reloaded")
    }
  end
  
end
