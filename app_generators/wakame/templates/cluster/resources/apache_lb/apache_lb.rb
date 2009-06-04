class Apache_LB < Wakame::Service::Resource
  include WebCluster::HttpLoadBalanceServer
  include Wakame::Service::ApacheBasicProps
  
  def_attribute :listen_port, {:default=>80}
  def_attribute :listen_port_https, {:default=>443}
  def_attribute :elastic_ip, {:default=>''}
  
  def render_config(template)
    template.cp(%w(conf/envvars-lb init.d/apache2-lb))
    template.render(%w(conf/system-lb.conf conf/apache2.conf conf/sites-lb.conf))
    template.chmod("init.d/apache2-lb", 0755)
  end

  def on_parent_changed(svc, action)
    action.deploy_configuration(svc_inst)
    action.trigger_action(Rule::ReloadService.new(svc_inst))
  end

  def start(svc, action)
    cond = ConditionalWait.new { |cond|
      cond.wait_event(Wakame::Event::ServiceOnline) { |event|
        event.instance_id == svc.instance_id
      }
    }

    request = action.actor_request(svc.agent.agent_id,
                                   '/service_monitor/register', svc.instance_id, :pidfile, '/var/run/apache2-lb.pid').request
    request = action.actor_request(svc.agent.agent_id,
                                   '/daemon/start', "apache_lb", 'init.d/apache2-lb').request
    #request.wait
    cond.wait

    Wakame.log.info("Associating the Elastic IP #{@elastic_ip} to #{svc.agent.agent_id}")
    VmManipulator.create.associate_address(svc.agent.agent_id, @elastic_ip)
  end
  
  def stop(svc, action)
    cond = ConditionalWait.new { |cond|
      cond.wait_event(Wakame::Event::ServiceOnline) { |event|
        event.instance_id == svc.instance_id
      }
    }

    request = action.actor_request(svc.agent.agent_id,
                                   '/daemon/stop', 'apache_lb', 'init.d/apache2-lb').request
    #request.wait
    cond.wait

    request = action.actor_request(svc.agent.agent_id,
                                   '/service_monitor/unregister', svc.instance_id ).request
  end

  def reload(svc, action)
    request = action.actor_request(svc.agent.agent_id,
                                   '/daemon/reload', "apache_lb", 'init.d/apache2-lb').request
    request.wait
  end
  
end
