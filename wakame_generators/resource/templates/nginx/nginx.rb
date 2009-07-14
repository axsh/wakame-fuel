
require 'wakame/rule'

class Nginx < Wakame::Service::Resource
  include WebCluster::HttpLoadBalanceServer
  
  def_attribute :listen_port, {:default=>80}
  def_attribute :listen_port_https, {:default=>443}
  
  def render_config(template)
    template.cp(%w(init.d/nginx))
    template.render(%w(conf/nginx.conf))
    template.chmod("init.d/nginx", 0755)
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
                                   '/service_monitor/register', svc.instance_id, :pidfile, '/var/run/nginx.pid').request
    action.actor_request(svc.agent.agent_id,
                         '/daemon/start', "nginx", 'init.d/nginx'){ |req|
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
                         '/daemon/stop', 'nginx', 'init.d/nginx'){ |req|
      req.wait
      Wakame.log.debug("#{self.class} process stopped")
    }

    cond.wait

    request = action.actor_request(svc.agent.agent_id,
                                   '/service_monitor/unregister', svc.instance_id ).request
  end

  def reload(svc, action)
    action.actor_request(svc.agent.agent_id,
                         '/daemon/reload', "nginx", 'init.d/nginx'){ |req|
      req.wait
      Wakame.log.debug("#{self.class} process reloaded")
    }
  end
  
end

