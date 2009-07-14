module Wakame
  module Actions
    class LaunchVM < Action
      def initialize(notes_key, ref_agent=nil)
        @ref_agent = ref_agent
        @notes_key = notes_key
      end

      USER_DATA_TMPL=<<__END__
node=agent
amqp_server=amqp://%s/
agent_id=%s
__END__

      def run
        require 'right_aws'
        ec2 = RightAws::Ec2.new(Wakame.config.aws_access_key, Wakame.config.aws_secret_key, {:cache=>false})

        # Fetch the reference vm slice attributes.
        @ref_agent ||= master.agent_monitor.master_local
        ref_attr = ec2.describe_instances([@ref_agent.attr[:instance_id]])
        ref_attr = ref_attr[0]
        

        user_data = sprintf(USER_DATA_TMPL, master.attr[:local_ipv4], '')
        Wakame.log.debug("#{self.class}: Lauching VM: #{ref_attr.inspect}\nuser_data: #{user_data}")
        res = ec2.run_instances(ref_attr[:aws_image_id], 1, 1,
                                ref_attr[:aws_groups],
                                ref_attr[:ssh_key_name],
                                user_data,
                                'public', # addressing_type
                                ref_attr[:aws_instance_type], # instance_type
                                nil, # kernel_id
                                nil, # ramdisk_id
                                ref_attr[:aws_availability_zone], # availability_zone
                                nil # block_device_mappings
                                )[0]
        inst_id = res[:aws_instance_id]

        ConditionalWait.wait { | cond |
          cond.wait_event(Event::AgentMonitored) { |event|
            event.agent.attr[:instance_id] == inst_id
          }
          
          cond.poll(5, 100) {
            d = ec2.describe_instances([inst_id])[0]
            Wakame.log.debug("#{self.class}: Polling describe_instances(#{inst_id}): #{d[:aws_state]} ")
            d[:aws_state] == "running"
          }
        }

        notes[@notes_key] = inst_id

      end
    end
  end
end
