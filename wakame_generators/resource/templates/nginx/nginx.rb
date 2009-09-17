class Nginx < Wakame::Service::Resource
  include HttpServer
  
  property :listen_port, {:default=>80}
  property :listen_port_https, {:default=>443}
  
  def render_config(template)
    template.glob_basedir(%w(conf/nginx.conf conf/vh/*.conf)) { |d|
      template.render(d)
    }
    template.cp('init.d/nginx')
    template.chmod("init.d/nginx", 0755)
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
                                   '/service_monitor/register', svc.id, :pidfile, '/var/run/nginx.pid').request
    action.actor_request(svc.cloud_host.agent_id,
                         '/daemon/start', "nginx", 'init.d/nginx'){ |req|
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
                         '/daemon/stop', 'nginx', 'init.d/nginx'){ |req|
      req.wait
      Wakame.log.debug("#{self.class} process stopped")
    }

    cond.wait

    request = action.actor_request(svc.cloud_host.agent_id,
                                   '/service_monitor/unregister', svc.id ).request
  end

  def reload(svc, action)
    action.actor_request(svc.cloud_host.agent_id,
                         '/daemon/reload', "nginx", 'init.d/nginx'){ |req|
      req.wait
      Wakame.log.debug("#{self.class} process reloaded")
    }
  end
  
end

