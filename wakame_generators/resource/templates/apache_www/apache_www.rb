class Apache_WWW < Wakame::Service::Resource
  include HttpServer
  include HttpAssetServer

  property :listen_port, {:default=>8000}
  
  def render_config(template)
    template.glob_basedir(%w(conf/envvars-www init.d/apache2-www)) { |d|
      template.cp(d)
    }
    template.glob_basedir(%w(conf/system-www.conf conf/apache2.conf conf/vh/*.conf)) { |d|
      template.render(d)
    }
    template.chmod("init.d/apache2-www", 0755)
  end
  
  def start(svc, action)
    cond = ConditionalWait.new { |cond|
      cond.wait_event(Wakame::Event::ServiceOnline) { |event|
        event.instance_id == svc.id
      }
    }

    request = action.actor_request(svc.cloud_host.agent_id,
                                   '/service_monitor/register', svc.id, :pidfile, '/var/run/apache2-www.pid').request
    request = action.actor_request(svc.cloud_host.agent_id,
                                   '/daemon/start', "apache_www", 'init.d/apache2-www'){ |req|
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
                                   '/daemon/stop', 'apache_www', 'init.d/apache2-www'){ |req|
      req.wait
      Wakame.log.debug("#{self.class} process stooped")
    }
    cond.wait

    request = action.actor_request(svc.cloud_host.agent_id,
                                   '/service_monitor/unregister', svc.id ).request
  end
  
  def reload(svc, action)
    request = action.actor_request(svc.cloud_host.agent_id,
                                   '/daemon/reload', 'apache_www', 'init.d/apache2-www').request
    request.wait
  end
  
end
