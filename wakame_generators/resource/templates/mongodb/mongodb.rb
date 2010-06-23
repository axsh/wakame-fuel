class Mongodb < Wakame::Service::Resource

  property :name,    {:default => "mongodb"}
  property :daemon,  {:default => "/usr/sbin/mongod"}
  property :port,    {:default => 27017}
  property :dbpath,  {:default => "/var/lib/mongodb"}
  property :logpath, {:default => "/var/log/mongodb/mongodb.log"}
  property :pidpath, {:default => "/var/run/mongodb.pid"}

  update_attribute :monitors, {'/service' => {
      :type => :pidfile,
      :path => "/var/run/mongodb.pid"
    }
  }
  
  def render_config(template)
    template.glob_basedir(%w(conf/mongodb.conf init.d/mongodb)) { |d|
      template.render(d)
    }
    #template.cp("init.d/mongodb")
    template.chmod("init.d/mongodb", 0755)
  end

  def start(svc, action)
    cond = ConditionalWait.new { |cond|
      cond.wait_event(Wakame::Event::ServiceOnline) { |event|
        event.instance_id == svc.id
      }
    }

    action.actor_request(svc.cloud_host.agent_id,
                         '/daemon/start', "mongodb", "init.d/mongodb"){ |req|
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
                         '/daemon/stop', "mongodb", "init.d/mongodb"){ |req|
      req.wait
      Wakame.log.debug("#{self.class} process stopped")
    }

    cond.wait
  end

  def reload(svc, action)
    action.actor_request(svc.cloud_host.agent_id,
                         '/daemon/reload', "mongodb", "init.d/mongodb"){ |req|
      req.wait
      Wakame.log.debug("#{self.class} process reloaded")
    }
  end
  
end
