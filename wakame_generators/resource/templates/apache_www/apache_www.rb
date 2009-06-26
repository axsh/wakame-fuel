class Apache_WWW < Wakame::Service::Resource
  include Wakame::Service::ApacheBasicProps
  include WebCluster::HttpAssetServer

  def_attribute :listen_port, {:default=>8000}
  def_attribute :max_instances, {:default=>5}
  
  def render_config(template)
    template.cp(%w(conf/envvars-www init.d/apache2-www))
    template.render(%w(conf/system-www.conf conf/sites-www.conf conf/apache2.conf))
    template.chmod("init.d/apache2-www", 0755)
  end
  
  def start(svc, action)
    cond = ConditionalWait.new { |cond|
      cond.wait_event(Wakame::Event::ServiceOnline) { |event|
        event.instance_id == svc.instance_id
      }
    }

    request = action.actor_request(svc.agent.agent_id,
                                   '/service_monitor/register', svc.instance_id, :pidfile, '/var/run/apache2-www.pid').request
    request = action.actor_request(svc.agent.agent_id,
                                   '/daemon/start', "apache_www", 'init.d/apache2-www'){ |req|
      req.wait
      Wakame.log.debug("#{self.class} process started")
    }
    cond.wait
  end
  
  def stop(svc, action)
    cond = ConditionalWait.new { |cond|
      cond.wait_event(Wakame::Event::ServiceOffline) { |event|
        event.instance_id == svc.instance_id
      }
    }

    request = action.actor_request(svc.agent.agent_id,
                                   '/daemon/stop', 'apache_www', 'init.d/apache2-www'){ |req|
      req.wait
      Wakame.log.debug("#{self.class} process stooped")
    }
    cond.wait

    request = action.actor_request(svc.agent.agent_id,
                                   '/service_monitor/unregister', svc.instance_id ).request
  end
  
  def reload(svc, action)
    action.actor_request('/daemon/reload', 'apache_www', 'init.d/apache2-www') { |req|
      req.wait
      Wakame.log.debug("#{self.class} process reloaded")
    }
  end
  
end
