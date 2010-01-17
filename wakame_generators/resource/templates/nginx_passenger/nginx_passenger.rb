class Nginx_Passenger < Wakame::Service::Resource
  include HttpServer

  property :ec2_elb_front_fqdn
  property :ec2_elb_rails_root


  update_attribute :listen_port, 80
  update_attribute :listen_port_https, 443
  update_attribute :monitors, { '/service' => {
      :type => :pidfile,
      :path => '/var/run/nginx-passenger.pid'
    }
  }
  
  def render_config(template)
    template.glob_basedir(%w(conf/nginx-passenger.conf conf/vh/*.conf)) { |d|
      template.render(d)
    }
    template.cp('init.d/nginx-passenger')
    template.chmod("init.d/nginx-passenger", 0755)
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

    action.actor_request(svc.cloud_host.agent_id,
                         '/daemon/start', "nginx_passenger", 'init.d/nginx-passenger'){ |req|
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
                         '/daemon/stop', 'nginx_passenger', 'init.d/nginx-passenger'){ |req|
      req.wait
      Wakame.log.debug("#{self.class} process stopped")
    }

    cond.wait
  end

  def reload(svc, action)
    action.actor_request(svc.cloud_host.agent_id,
                         '/daemon/reload', "nginx_passenger", 'init.d/nginx-passenger'){ |req|
      req.wait
      Wakame.log.debug("#{self.class} process reloaded")
    }
  end
  
end

