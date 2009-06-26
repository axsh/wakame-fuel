class WebCluster < Wakame::Service::ServiceCluster
  attr_accessor :propagation_priority

  module HttpAppServer; end
  module HttpAssetServer; end
  module HttpLoadBalanceServer; end

  VirtualHost = Class.new(OpenStruct)
  def initialize(master, &blk)
    super(master) { |c|
      c.add_resource(Ec2ElasticIp.new)
      c.add_resource(Apache_WWW.new)
      c.add_resource(Apache_APP.new)
      c.add_resource(Apache_LB.new)
      c.add_resource(MySQL_Master.new)

      c.set_dependency(Apache_LB, Ec2ElasticIp)
      c.set_dependency(Apache_WWW, Apache_LB)
      c.set_dependency(Apache_APP, Apache_LB)
      c.set_dependency(MySQL_Master, Apache_APP)
    }

    define_rule { |r|
      r.register_trigger(Wakame::Triggers::ProcessCommand.new)
      r.register_trigger(Wakame::Triggers::MaintainSshKnownHosts.new)
      #r.register_trigger(Wakame::Triggers::LoadHistoryMonitor.new)
      #r.register_trigger(Wakame::Triggers::InstanceCountUpdate.new)
      #r.register_trigger(Wakame::Triggers::ScaleOutWhenHighLoad.new)
      #r.register_trigger(Wakame::Triggers::ShutdownUnusedVM.new)
    }

     add_virtual_host(VirtualHost.new(:server_name=>'aaa.test', :document_root=>'/home/wakame/app/development/test/public'))
     add_virtual_host(VirtualHost.new(:server_name=>'bbb.test', :document_root=>'/home/wakame/app/development/test/public'))

  end

  def virtual_hosts
    @virtual_hosts ||= []
  end

  def add_virtual_host(vh)
    virtual_hosts << vh
  end


  def each_app(&blk)
    each_instance(HttpAppServer) { |n|
      blk.call(n)
    }
  end

  def each_www(&blk)
    each_instance(HttpAssetServer) { |n|
      blk.call(n)
    }
  end

  def each_mysql(&blk)
    each_instance(MySQL_Master) { |n|
      blk.call(n)
    }
  end

end
