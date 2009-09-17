class Apache_APP < Wakame::Service::Resource
  include HttpServer
  include HttpApplicationServer

  def_attribute :listen_port, {:default=>8001}
  def_attribute :listen_port_https, {:default=>443}

  def render_config(template)
    template.glob_basedir(%w(conf/envvars-app init.d/apache2-app)) { |d|
      template.cp(d)
    }
    template.glob_basedir(%w(conf/system-app.conf conf/apache2.conf conf/vh/*.conf)) { |d|
      template.render(d)
    }
    template.chmod("init.d/apache2-app", 0755)
  end


  def start(svc, action)
    cond = ConditionalWait.new { |cond|
      cond.wait_event(Wakame::Event::ServiceOnline) { |event|
        event.instance_id == svc.id
      }
    }

    request = action.actor_request(svc.cloud_host.agent_id,
                                   '/service_monitor/register', svc.id, :pidfile, '/var/run/apache2-app.pid').request
    action.actor_request(svc.cloud_host.agent_id,
                         '/daemon/start', "apache_app", 'init.d/apache2-app'){ |req|
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

    request = action.actor_request(svc.cloud_host.agent_id,
                                   '/daemon/stop', 'apache_app', 'init.d/apache2-app'){ |req|
      req.wait
      Wakame.log.debug("#{self.class} process stopped")
    }
    cond.wait

    request = action.actor_request(svc.cloud_host.agent_id,
                                   '/service_monitor/unregister', svc.id ).request
  end

  def reload(svc, action)
    request = action.actor_request(svc.cloud_host.agent_id,
                                   '/daemon/reload', "apache_app", 'init.d/apache2-app').request
    request.wait
  end

end
