
require 'wakame/rule'

class Apache_LB < Wakame::Service::Resource
  include WebCluster::HttpLoadBalanceServer
  include Wakame::Service::ApacheBasicProps
  
  def_attribute :listen_port, {:default=>80}
  def_attribute :listen_port_https, {:default=>443}
  
  def render_config(template)
    template.cp(%w(conf/envvars-lb init.d/apache2-lb))
    template.render(%w(conf/system-lb.conf conf/apache2.conf conf/sites-lb.conf))
    template.chmod("init.d/apache2-lb", 0755)
  end

  def on_parent_changed(svc, action)
    Wakame::Rule::BasicActionSet.deploy_configuration(svc)
    reload(svc, action)
  end

  def start(svc, action)
    cond = ConditionalWait.new { |cond|
      cond.wait_event(Wakame::Event::ServiceOnline) { |event|
        event.instance_id == svc.instance_id
      }
    }

    request = action.actor_request(svc.agent.agent_id,
                                   '/service_monitor/register', svc.instance_id, :pidfile, '/var/run/apache2-lb.pid').request
    action.actor_request(svc.agent.agent_id,
                         '/daemon/start', "apache_lb", 'init.d/apache2-lb'){ |req|
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

    action.actor_request(svc.agent.agent_id,
                         '/daemon/stop', 'apache_lb', 'init.d/apache2-lb'){ |req|
      req.wait
      Wakame.log.debug("#{self.class} process stopped")
    }

    cond.wait

    request = action.actor_request(svc.agent.agent_id,
                                   '/service_monitor/unregister', svc.instance_id ).request
  end

  def reload(svc, action)
    action.actor_request(svc.agent.agent_id,
                         '/daemon/reload', "apache_lb", 'init.d/apache2-lb'){ |req|
      req.wait
      Wakame.log.debug("#{self.class} process stopped")
    }
  end
  
end
