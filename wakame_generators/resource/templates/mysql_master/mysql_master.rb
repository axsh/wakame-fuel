
class MySQL_Master < Wakame::Service::Resource

  def_attribute :duplicable, false
  def_attribute :mysqld_basedir, '/home/wakame/mysql'
  def_attribute :mysqld_port, 3306

  def_attribute :ebs_volume, ''
  def_attribute :ebs_device, '/dev/sdm'
  def_attribute :ebs_mount_option, 'noatime'

  def_attribute :repl_user, 'wakame-repl'
  def_attribute :repl_pass, 'wakame-slave'

  def basedir
    File.join(Wakame.config.root_path, 'cluster', 'resources', 'mysql_master')
  end
  
  def mysqld_datadir
    File.expand_path('data', mysqld_basedir)
  end

  def mysqld_log_bin
    File.expand_path('mysql-bin.log', mysqld_datadir)
  end

  def render_config(template)
    template.cp(%w(init.d/mysql))
    template.render(%w(conf/my.cnf))
    template.chmod("init.d/mysql", 0755)
  end

  def start(svc, action)
    require 'right_aws'
    ec2 = RightAws::Ec2.new(Wakame.config.aws_access_key, Wakame.config.aws_secret_key)

    res = ec2.describe_volumes([self.ebs_volume])[0]
    ec2_instance_id = res[:aws_instance_id]
    if res[:aws_status] == 'in-use' && ec2_instance_id == svc.agent.attr[:instance_id]
       # Nothin to be done
    elsif res[:aws_status] == 'in-use' && ec2_instance_id != svc.agent.attr[:instance_id]
      ec2.detach_volume(self.ebs_volume)
      cond = ConditionalWait.new { |c|
        c.poll {
          res1 = ec2.describe_volumes([self.ebs_volume])[0]
          res1[:aws_status] == 'available'
        }
      }
      cond.wait

      ec2.attach_volume(self.ebs_volume, svc.agent.attr[:instance_id], self.ebs_device)
      cond = ConditionalWait.new { |c|
        c.poll {
          res1 = ec2.describe_volumes([self.ebs_volume])[0]
          res1[:aws_status] == 'in-use'
        }
      }
      cond.wait

    elsif res[:aws_status] == 'available'
      ec2.attach_volume(self.ebs_volume, svc.agent.attr[:instance_id], self.ebs_device)
      cond = ConditionalWait.new { |c|
        c.poll {
          res1 = ec2.describe_volumes([self.ebs_volume])[0]
          res1[:aws_status] == 'in-use'
        }
      }
      cond.wait
    end

    cond = ConditionalWait.new { |cond|
      cond.wait_event(Wakame::Event::ServiceOnline) { |event|
        event.instance_id == svc.instance_id
      }
    }

    action.actor_request(svc.agent.agent_id,
                         '/service_monitor/register',
                         svc.instance_id,
                         :command, "/usr/bin/mysqladmin --defaults-file=#{svc.agent.root_path}/tmp/config/mysql_master/conf/my.cnf ping > /dev/null") { |req|
    }

    action.actor_request(svc.agent.agent_id, '/system/sync') { |req|
      req.wait
      Wakame.log.debug("sync")
    }

    action.actor_request(svc.agent.agent_id, '/system/mount', self.ebs_device, self.mysqld_datadir, self.ebs_mount_option) { |req|
      req.wait
      Wakame.log.debug("MySQL volume was mounted: #{self.mysqld_datadir}")
    }

    action.actor_request(svc.agent.agent_id, '/daemon/start', 'mysql_master', 'init.d/mysql') { |req|
      req.wait
      Wakame.log.debug("MySQL process started")
    }

    cond.wait
  end
  
  def stop(svc, action)
    cond = ConditionalWait.new { |c|
      c.wait_event(Wakame::Event::ServiceOffline) { |event|
        event.instance_id == svc.instance_id
      }
    }    
    action.actor_request(svc.agent.agent_id, '/daemon/stop', 'mysql_master', 'init.d/mysql') { |req| req.wait }
    action.actor_request(svc.agent.agent_id, '/system/umount', self.mysqld_datadir) { |req|
      req.wait
      Wakame.log.debug("MySQL volume unmounted")
    }
    cond.wait

    action.actor_request(svc.agent.agent_id,
                         '/service_monitor/unregister',
                         svc.instance_id).request
  end
end
