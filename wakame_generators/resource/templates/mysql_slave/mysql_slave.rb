
class MySQL_Slave < Wakame::Service::Resource

  def_attribute :duplicable, true
  def_attribute :max_instances, {:default=>5}

  def_attribute :mysqld_basedir, '/home/wakame/mysql'
  def_attribute :mysqld_port, 3307

  def_attribute :ebs_device, '/dev/sdn'
  def_attribute :ebs_mount_option, 'noatime'

  def basedir
    File.join(Wakame.config.root_path, 'cluster', 'resources', 'mysql_slave')
  end
  
  def mysqld_datadir
    File.expand_path('data-slave', mysqld_basedir)
  end

  def mysqld_log_bin
    File.expand_path('mysql-bin.log', mysqld_datadir)
  end

  def render_config(template)
    template.cp(%w(init.d/mysql-slave))
    template.render(%w(conf/my.cnf))
    template.chmod("init.d/mysql-slave", 0755)
  end

  def start(svc, action)
    cond = ConditionalWait.new { |cond|
      cond.wait_event(Wakame::Event::ServiceOnline) { |event|
        event.instance_id == svc.instance_id
      }
    }

    action.actor_request(svc.agent.agent_id,
                         '/service_monitor/register',
                         svc.instance_id,
                         :command, "/usr/bin/mysqladmin --defaults-file=#{svc.agent.root_path}/tmp/config/mysql_slave/conf/my.cnf ping > /dev/null") { |req|
    }

    opt_map = {
      :aws_access_key => Wakame.config.aws_access_key,
      :aws_secret_key => Wakame.config.aws_secret_key,
      :ebs_device     => self.ebs_device,
      :master_ip      => svc.cluster.fetch_mysql_master_ip,
    }
    svc.cluster.each_instance(MySQL_Master) { |mysql_master|
      opt_map[:master_port]           = mysql_master.resource.mysqld_port
      opt_map[:master_ebs_volume]     = mysql_master.resource.ebs_volume
      opt_map[:master_mysqld_datadir] = mysql_master.resource.mysqld_datadir
      opt_map[:repl_user]             = mysql_master.resource.repl_user
      opt_map[:repl_pass]             = mysql_master.resource.repl_pass
    }

    action.actor_request(svc.agent.agent_id, '/mysql/take_master_snapshot', opt_map) { |req|
      req.wait
      Wakame.log.debug("take-master-snapshot!!")
    }

    action.actor_request(svc.agent.agent_id, '/system/sync') { |req|
      req.wait
      Wakame.log.debug("sync")
    }

    action.actor_request(svc.agent.agent_id, '/system/mount', self.ebs_device, self.mysqld_datadir, self.ebs_mount_option) { |req|
      req.wait
      Wakame.log.debug("MySQL volume was mounted: #{self.mysqld_datadir}")
    }

    action.actor_request(svc.agent.agent_id, '/daemon/start', 'mysql_slave', 'init.d/mysql-slave') { |req|
      req.wait
      Wakame.log.debug("MySQL process started")
    }

  end
  
  def stop(svc, action)
    cond = ConditionalWait.new { |c|
      c.wait_event(Wakame::Event::ServiceOffline) { |event|
        event.instance_id == svc.instance_id
      }
    }
    action.actor_request(svc.agent.agent_id, '/daemon/stop', 'mysql_slave', 'init.d/mysql-slave') { |req| req.wait }
    action.actor_request(svc.agent.agent_id, '/system/umount', self.mysqld_datadir) { |req|
      req.wait
      Wakame.log.debug("MySQL volume unmounted")
    }
    cond.wait

    require 'right_aws'
    ec2 = RightAws::Ec2.new(Wakame.config.aws_access_key, Wakame.config.aws_secret_key)
    ec2.describe_volumes.each do |volume|
      next unless volume[:aws_instance_id] == svc.agent.agent_id && volume[:aws_device] == self.ebs_device

      @ebs_volume = volume[:aws_id]

      # detach volume
      res = ec2.detach_volume(@ebs_volume)
      Wakame.log.debug("detach_volume : #{res.inspect}")
      # waiting for available
      cond = ConditionalWait.new { |c|
        c.poll {
          res = ec2.describe_volumes([@ebs_volume])[0]
          res[:aws_status] == 'available'
        }
      }
      cond.wait

      # delete mysql-slave snapshot volume
      res = ec2.delete_volume(@ebs_volume)
      Wakame.log.debug("delete_volume : #{res.inspect}")
    end

    # unregister
    action.actor_request(svc.agent.agent_id,
                         '/service_monitor/unregister',
                         svc.instance_id).request

  end
end
