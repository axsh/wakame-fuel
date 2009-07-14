
class MySQL_Master < Wakame::Service::Resource

  def_attribute :duplicable, false
  def_attribute :mysqld_basedir, '/home/wakame/mysql'
  def_attribute :mysqld_server_id, 1
  def_attribute :mysqld_port, 3306

  def_attribute :ebs_volume, ''
  def_attribute :ebs_device, '/dev/sdm'
  def_attribute :ebs_mount_option, 'noatime'

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
    vm_manipulator = Wakame::VmManipulator.create

    # $ echo "GRANT REPLICATION SLAVE, REPLICATION CLIENT, RELOAD ON *.* TO 'wakame-repl'@'%' IDENTIFIED BY 'wakame-slave';" | /usr/bin/mysql -h#{mysql_master_ip} -uroot

    require 'right_aws'
    ec2 = RightAws::Ec2.new(Wakame.config.aws_access_key, Wakame.config.aws_secret_key)

    res = ec2.describe_volumes([@ebs_volume])[0]
    ec2_instance_id = res[:aws_instance_id]
    if res[:aws_status] == 'in-use' && ec2_instance_id == svc.agent.attr[:instance_id]
       # Nothin to be done
    elsif res[:aws_status] == 'in-use' && ec2_instance_id != svc.agent.attr[:instance_id]
      ec2.detach_volume(@ebs_volume)
      cond = ConditionalWait.new { |c|
        c.poll {
          res1 = ec2.describe_volumes([@ebs_volume])[0]
          res1[:aws_status] == 'available'
        }
      }
      cond.wait

      ec2.attach_volume(@ebs_volume, svc.agent.attr[:instance_id], @ebs_device)
      cond = ConditionalWait.new { |c|
        c.poll {
          res1 = ec2.describe_volumes([@ebs_volume])[0]
          res1[:aws_status] == 'in-use'
        }
      }
      cond.wait

    elsif res[:aws_status] == 'available'
      ec2.attach_volume(@ebs_volume, svc.agent.attr[:instance_id], @ebs_device)
      cond = ConditionalWait.new { |c|
        c.poll {
          res1 = ec2.describe_volumes([@ebs_volume])[0]
          res1[:aws_status] == 'in-use'
        }
      }
      cond.wait
      
    end
    # in-use:
#    res = vm_manipulator.describe_volume(@ebs_volume)
#    Wakame.log.debug("describe_volume(#{@ebs_volume}): #{res.inspect}")
#    ec2_instance_id=nil
#     if res['attachmentSet']
#       ec2_instance_id = res['attachmentSet']['item'][0]['instanceId']
#     end

#     if res['status'] == 'in-use' && ec2_instance_id == svc.agent.agent_id
#       # Nothin to be done
#     elsif res['status'] == 'in-use' && ec2_instance_id != svc.agent.agent_id
#       vm_manipulator.detach_volume(@ebs_volume)
#       sleep 1.0
#       res = vm_manipulator.attach_volume(svc.agent.agent_id, @ebs_volume, @ebs_device)
#       Wakame.log.debug(res.inspect)
#       # sync
#       3.times do |i|
#         system("/bin/sync")
#         sleep 1.0
#       end
#     elsif res['status'] == 'available'
#       res = vm_manipulator.attach_volume(svc.agent.agent_id, @ebs_volume, @ebs_device)
#       Wakame.log.debug(res.inspect)
#       # sync
#       3.times do |i|
#         system("/bin/sync")
#         sleep 1.0
#       end
#     else
#       raise "The EBS volume is not ready to attach: #{@ebs_volume}"
#     end

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

    action.actor_request(svc.agent.agent_id, '/system/mount', @ebs_device, @mysqld_datadir, @ebs_mount_option) { |req|
      req.wait
      Wakame.log.debug("MySQL volume was mounted: #{@mysqld_datadir}")
    }

    action.actor_request(svc.agent.agent_id, '/daemon/start', 'mysql_master', 'init.d/mysql') { |req|
      req.wait
      Wakame.log.debug("MySQL process started")
    }

    #request.wait
    cond.wait


#     mount_point_dev=`df "#{@mysqld_datadir}" | awk 'NR==2 {print $1}'`
#     if mount_point_dev != @ebs_device
#       Wakame.log.debug("Mounting EBS volume: #{@ebs_device} as #{@mysqld_datadir} (with option: #{@ebs_mount_option})")
#       system("/bin/mount -o #{@ebs_mount_option} #{@ebs_device} #{@mysqld_datadir}")
#       # sync
#       3.times do |i|
#         system("/bin/sync")
#         sleep 1.0
#       end
#     end
#     system(Wakame.config.root + "/config/init.d/mysql start")
  end
  
  #def check
  #  system("/usr/bin/mysqladmin --defaults-file=/home/wakame/config/mysql/my.cnf ping > /dev/null")
  #  return false if $? != 0
  #  true
  #end
  
  def stop(svc, action)
    cond = ConditionalWait.new { |c|
      c.wait_event(Wakame::Event::ServiceOffline) { |event|
        event.instance_id == svc.instance_id
      }
    }
    
    action.actor_request(svc.agent.agent_id, '/daemon/stop', 'mysql_master', 'init.d/mysql') { |req| req.wait }
    action.actor_request(svc.agent.agent_id, '/system/umount', @mysqld_datadir) { |req|
      req.wait
      Wakame.log.debug("MySQL volume unmounted")
    }

    #request.wait
    cond.wait

    action.actor_request(svc.agent.agent_id,
                         '/service_monitor/unregister',
                         svc.instance_id).request


    #system(Wakame.config.root + "/config/init.d/mysql stop")
  end
end
