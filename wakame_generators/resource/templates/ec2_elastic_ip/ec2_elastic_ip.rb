class Ec2ElasticIp < Wakame::Service::Resource
  
  def_attribute :elastic_ip, ''
  def_attribute :require_agent, false
  
  def on_parent_changed(svc, action)
    start(svc, action)
  end

  def start(svc, action)
    require 'right_aws'
    ec2 = RightAws::Ec2.new(Wakame.config.aws_access_key, Wakame.config.aws_secret_key)

    puts svc.parent_instances.size.to_s
    a = svc.parent_instances.first

    puts "#{a.class}, a.agent=#{a.agent}"
    Wakame.log.info("Associating the Elastic IP #{self.elastic_ip} to #{a.agent.attr[:instance_id]}")
    ec2.associate_address(a.agent.attr[:instance_id], self.elastic_ip)
    EM.barrier {
      svc.update_status(Wakame::Service::STATUS_ONLINE)
    }
  end
  
  def stop(svc, action)
    require 'right_aws'
    ec2 = RightAws::Ec2.new(Wakame.config.aws_access_key, Wakame.config.aws_secret_key)

    a = svc.parent_instances.first

    #Wakame.log.info("Disassociating the Elastic IP #{self.elastic_ip} from #{a.agent.attr[:instance_id]}")
    #ec2.disassociate_address(self.elastic_ip)
    EM.barrier {
      svc.update_status(Wakame::Service::STATUS_OFFLINE)
    }

  end

end
