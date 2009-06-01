class Apache_WWW < Wakame::Service::Resource
  include Wakame::Service::ApacheBasicProps
  include WebCluster::HttpAssetServer

  def_attribute :listen_port, {:default=>8000, :persistence=>true}
  def_attribute :max_instances, {:default=>5, :persistence=>false}
  
  def render_config(template)
    template.cp(%w(conf/envvars-www init.d/apache2-www))
    template.render(%w(conf/system-www.conf conf/sites-www.conf conf/apache2.conf))
    template.chmod("init.d/apache2-www", 0755)
  end
  
  def start(svc, action)
    request = action.actor_request(svc.agent.agent_id,
                                   '/service_monitor/register', svc.instance_id, :pidfile, '/var/run/apache2-www.pid').request
    request = action.actor_request(svc.agent.agent_id,
                                   '/daemon/start', "apache_www", 'init.d/apache2-www').request
    #request.wait

    ConditionalWait.wait { |cond|
      cond.wait_event(Wakame::Event::ServiceOnline) { |event|
        event.instance_id == svc.instance_id
      }
    }
  end
  
  def stop(svc, action)
    request = action.actor_request(svc.agent.agent_id,
                                   '/daemon/stop', 'apache_www', 'init.d/apache2-www').request
    #request.wait

    ConditionalWait.wait { |cond|
      cond.wait_event(Wakame::Event::ServiceOffline) { |event|
        event.instance_id == svc.instance_id
      }
    }

    request = action.actor_request(svc.agent.agent_id,
                                   '/service_monitor/unregister', svc.instance_id ).request
  end
  
  def reload(svc, action)
    request = action.actor_request('/daemon/reload', 'apache_www', 'init.d/apache2-www').request
    request.wait
  end
  
end
