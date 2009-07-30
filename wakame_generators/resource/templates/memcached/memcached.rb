require 'wakame/rule'

class Memcached < Wakame::Service::Resource

  def_attribute :duplicable, true
  def_attribute :max_instances, {:default=>5}
  
  def_attribute :listen_port,  {:default => 11211 }
  def_attribute :bind_address, {:default => '127.0.0.1'}
  def_attribute :memory_size,  {:default => 64}
  def_attribute :user,         {:default => 'nobody'}

  def render_config(template)
    template.cp(%w(init.d/memcached))
    template.render(%w(conf/memcached.conf))
    template.chmod("init.d/memcached", 0755)
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
                                   '/service_monitor/register',
                                   svc.instance_id, :pidfile, '/var/run/memcached.pid').request
    action.actor_request(svc.agent.agent_id,
                         '/daemon/start', "memcached", 'init.d/memcached'){ |req|
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
                         '/daemon/stop', 'memcached', 'init.d/memcached'){ |req|
      req.wait
      Wakame.log.debug("#{self.class} process stopped")
    }

    cond.wait

    request = action.actor_request(svc.agent.agent_id,
                                   '/service_monitor/unregister', svc.instance_id).request
  end

  def reload(svc, action)
    action.actor_request(svc.agent.agent_id,
                         '/daemon/stop', 'memcached', 'init.d/memcached'){ |req|
      req.wait
      # Wakame.log.debug("#{self.class} process stopped")
    }

    action.actor_request(svc.agent.agent_id,
                         '/daemon/start', "memcached", 'init.d/memcached'){ |req|
      req.wait
      # Wakame.log.debug("#{self.class} process started")
      Wakame.log.debug("#{self.class} process reloaded")
    }
  end
  
end
