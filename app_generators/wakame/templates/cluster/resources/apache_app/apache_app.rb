class Apache_APP < Wakame::Service::Resource
  include Wakame::Service::ApacheBasicProps
  include WebCluster::HttpAppServer

  def_attribute :listen_port, {:default=>8001}
  def_attribute :listen_port_https, {:default=>443}
  def_attribute :max_instance, {:default=>5}

  def render_config(template)
    template.cp(%w(conf/envvars-app init.d/apache2-app))
    template.render(%w(conf/system-app.conf conf/apache2.conf conf/sites-app.conf))
    template.chmod("init.d/apache2-app", 0755)
  end


  def start(svc, action)
    cond = ConditionalWait.new { |cond|
      cond.wait_event(Wakame::Event::ServiceOnline) { |event|
        event.instance_id == svc.instance_id
      }
    }

    request = action.actor_request(svc.agent.agent_id,
                                   '/service_monitor/register', svc.instance_id, :pidfile, '/var/run/apache2-app.pid').request
    request = action.actor_request(svc.agent.agent_id,
                                   '/daemon/start', "apache_app", 'init.d/apache2-app').request
    #request.wait
    cond.wait
  end
  

  def stop(svc, action)
    cond = ConditionalWait.new { |cond|
      cond.wait_event(Wakame::Event::ServiceOffline) { |event|
        event.instance_id == svc.instance_id
      }
    }

    request = action.actor_request(svc.agent.agent_id,
                                   '/daemon/stop', 'apache_app', 'init.d/apache2-app').request
    #request.wait
    cond.wait

    request = action.actor_request(svc.agent.agent_id,
                                   '/service_monitor/unregister', svc.instance_id ).request
  end

  def reload(svc, action)
    request = action.actor_request(svc.agent.agent_id,
                                   '/daemon/reload', "apache_app", 'init.d/apache2-app').request
    request.wait
  end

end