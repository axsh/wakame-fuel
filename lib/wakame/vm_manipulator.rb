
require 'wakame'

module Wakame
  module VmManipulator
    def self.create
      Wakame.new_([self.to_s, Wakame.config.vm_environment ].join('::'))
    end

    class Base
      def start_instance(attr)
      end

      def stop_instance(instance_id)
      end
      
      # expected_status : :online, :offline, :failed
      def check_status(instance_id, expected_status=:online)
      end

      # Expected common keys/attributes when returned.
      # local_ipv4 : Internal IP address which is assigned to the VM instance.
      # local_hostname : Internal hostname assigned to the VM instance.
      def fetch_local_attrs
        
      end
    end

    class StandAlone < Base
      def start_instance(attr)
        # Nothing to be done
        {:instance_id => 'standalone'}
      end

      def stop_instance(instance_id)
        # Nothing to be done
      end

      def check_status(instance_id, expected_status=:online)
        # Always running
        expected_status == :online
      end

      def fetch_local_attrs
        attrs = {:instance_id=>'__stand_alone__', :local_ipv4=>'127.0.0.1', :local_hostname=>'localhost'}
        attrs
      end
    end

    class EC2 < Base
      require 'EC2'

      def initialize()
        @ec2 = ::EC2::Base.new(:access_key_id => Wakame.config.aws_access_key, :secret_access_key => Wakame.config.aws_secret_key )
      end
      
      def start_instance(image_id, attr={})
        res = @ec2.run_instances(:image_id => image_id,
                                 :availability_zone => attr[:availability_zone],
                                 :group_id => attr[:security_groups],
                                 :instance_type => attr[:instance_type],
                                 :user_data => attr[:user_data]
                                 )
        {:instance_id => res.instancesSet.item[0].instanceId}
      end

      def stop_instance(instance_id)
        @ec2.terminate_instances()
      end

      def check_status(instance_id, expected_status=:online)
        res = @ec2.describe_instances(:instance_id => instance_id)

        status = res.reservationSet.item[0].instancesSet.item[0].instanceState
        # status is returned in a hash structure. i.e. {'name'=>'running', 'code'=>'16' }
        Wakame.log.debug("VM (#{instance_id}) status: #{status['name']}")
        return case status['name']
               when "running"
                 expected_status == :online
               when "terminated"
                 expected_status == :offline
               when "rebooting"
                 expected_status == :offline
               when "starting"
                 expected_status == :offline
               when "pending"
                 expected_status == :offline
               else
                 raise "Unknown status from AWS: #{status['name']}"
               end
      end

      def associate_address(instance_id, ip_addr)
        res = @ec2.associate_address(:instance_id=>instance_id, :public_ip=>ip_addr)
        # {"requestId"=>"000ac66b-4a9c-43be-8176-b1b96ed6d4b7", "return"=>"true", "xmlns"=>"http://ec2.amazonaws.com/doc/2008-12-01/"}
        res['return'] == 'true'
      end
      def disassociate_address(ip_addr)
        res = @ec2.disassociate_address(:public_ip=>ip_addr)
        # {"requestId"=>"2f38c8bb-4b1a-4df3-9f30-fa17317c89c4", "return"=>"true", "xmlns"=>"http://ec2.amazonaws.com/doc/2008-12-01/"}
        res['return'] == 'true'
      end

      def describe_volume(vol_id)
        res = @ec2.describe_volumes(:volume_id=>vol_id)
        if res['volumeSet']['item'][0]['attachmentSet']
          res['volumeSet']['item'][0]['attachmentSet']['item'][0]
        else
          res['volumeSet']['item'][0]
        end
      end      

      def attach_volume(instance_id, vol_id, vol_dev)
        res = @ec2.attach_volume(:instance_id=>instance_id, :volume_id=>vol_id, :device=>vol_dev)
      end
      def detach_volume(vol_id)
        res = @ec2.detach_volume(:volume_id=>vol_id)
      end

      def request_internal_aws(key)
        require 'open-uri'
        open("http://169.254.169.254/2008-02-01/meta-data/#{key}") { |f|
          return f.readline
        }
      end

      def fetch_local_attrs
        attrs = {}
        %w[instance-id instance-type local-ipv4 local-hostname public-hostname public-ipv4 ami-id].each { |key|
          rkey = key.tr('-', '_')
          attrs[rkey.to_sym]=request_internal_aws(key)
        }
        attrs
      end

    end

  end
end
