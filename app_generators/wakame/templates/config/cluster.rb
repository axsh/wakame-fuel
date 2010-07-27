Wakame.log.debug("WAKAME_CLUSTER_ENV=#{Wakame.config.cluster_env}")

case Wakame.config.cluster_env
when  'development'
    ec2_elb_front_fqdn = 'www.d.example.com'
    elb_name = ''
when  'test'
    ec2_elb_front_fqdn = 'www.t.example.com'
    elb_name = ''
when  'qa'
    ec2_elb_front_fqdn = 'www.q.example.com'
    elb_name = ''
when  'production'
    ec2_elb_front_fqdn = 'www.example.com'
    elb_name = ''
end


define_cluster('WebCluster1') { |c|
  c.add_resource(Apache_APP.new) { |r|
    r.listen_port = 8001
    r.max_instances = 5
  }
  c.add_resource(Nginx.new)
  c.add_resource(Ec2ELB.new) { |r|
    r.elb_name = elb_name
  }
  c.add_resource(MySQL_Master.new) {|r|
    r.mysqld_basedir = '/home/wakame/mysql'
    r.ebs_volume = 'vol-xxxxxxx'
    r.ebs_device = '/dev/sdm'
  }
  
  c.set_dependency(Apache_APP, Nginx)
  c.set_dependency(Nginx, Ec2ELB)
  c.set_dependency(MySQL_Master, Apache_APP)

  host = c.add_cloud_host { |h|
    #h.vm_spec.availability_zone = 'us-east-1a'
  }
  c.propagate(Nginx, host.id)
  c.propagate(Apache_APP, host.id)
  c.propagate(MySQL_Master, host.id)
  c.propagate(Ec2ELB)

  c.define_triggers {|r|
    #r.register_trigger(Wakame::Triggers::MaintainSshKnownHosts.new)
    #r.register_trigger(Wakame::Triggers::LoadHistoryMonitor.new)
    #r.register_trigger(Wakame::Triggers::InstanceCountUpdate.new)
    #r.register_trigger(Wakame::Triggers::ScaleOutWhenHighLoad.new)
    #r.register_trigger(Wakame::Triggers::ShutdownUnusedVM.new)
  }

}

