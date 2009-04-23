
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
        @ec2.terminate_instances(:instance_id=>instance_id)
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

      # volume
      def describe_volume(vol_id)
        res = @ec2.describe_volumes(:volume_id=>vol_id)
        if res['volumeSet']['item'][0]['attachmentSet']
          res['volumeSet']['item'][0]['attachmentSet']['item'][0]
        else
          res['volumeSet']['item'][0]
        end
      end
# >> @ec2.attach_volume(:instance_id => 'i-1fa1cd76', :volume_id => "vol-1f927176", :device=>'/dev/sde')
#      => {"attachTime"=>"2009-04-17T05:46:18.000Z", "status"=>"attaching", "device"=>"/dev/sde", "requestId"=>"0fd3797b-b4f9-476b-8cb2-3e7401c6fae2", "instanceId"=>"i-1fa1cd76", "volumeId"=>"vol-1f927176", "xmlns"=>"http://ec2.amazonaws.com/doc/2008-12-01/"}
      def attach_volume(instance_id, vol_id, vol_dev)
        res = @ec2.attach_volume(:instance_id=>instance_id, :volume_id=>vol_id, :device=>vol_dev)
      end
      def detach_volume(vol_id)
        res = @ec2.detach_volume(:volume_id=>vol_id)
      end

      # volume
# >> @ec2.describe_volumes(:volume_id => "vol-c58360ac")
#      => {"volumeSet"=>{"item"=>[{"status"=>"available", "size"=>"1", "snapshotId"=>nil, "availabilityZone"=>"us-east-1a", "attachmentSet"=>nil, "createTime"=>"2009-04-16T09:56:01.000Z", "volumeId"=>"vol-c58360ac"}]}, "requestId"=>"0e6d0923-eba8-425a-b939-87c7fe8e835e", "xmlns"=>"http://ec2.amazonaws.com/doc/2008-12-01/"}
      def describe_volume(vol_id)
        res = @ec2.describe_volumes(:volume_id=>vol_id)
        res['volumeSet']['item'][0]
      end
      def create_volume(availability_zone, size)
        res = @ec2.create_volume(:availability_zone=>availability_zone, :size=>size)
      end
# >> @ec2.create_volume(:availability_zone=>"us-east-1b", :snapshot_id=>"snap-27c1324e")
#      => {"status"=>"creating", "size"=>"1", "snapshotId"=>"snap-27c1324e", "requestId"=>"f3a0ddbf-9eb8-4594-b43e-8486459a0168", "availabilityZone"=>"us-east-1b", "createTime"=>"2009-04-17T05:44:58.000Z", "volumeId"=>"vol-1f927176", "xmlns"=>"http://ec2.amazonaws.com/doc/2008-12-01/"}
      def create_volume_from_snapshot(availability_zone, snapshot_id)
        res = @ec2.create_volume(:availability_zone=>availability_zone, :snapshot_id=>snapshot_id)
      end
      def delete_volume(vol_id)
        res = @ec2.delete_volume(:volume_id=>vol_id)
      end

      # snapshot
      def describe_snapshot(snapshot_id)
        res = @ec2.describe_snapshots(:snapshot_id=>snapshot_id)
        res['snapshotSet']['item'][0]
      end

# >> @ec2.create_snapshot(:volume_id => 'vol-c58360ac')
#      => {"status"=>"pending", "snapshotId"=>"snap-18c13271", "requestId"=>"9d1d586a-44b7-4edd-b94a-aaccb54e888d", "progress"=>nil, "startTime"=>"2009-04-16T10:13:37.000Z", "volumeId"=>"vol-c58360ac", "xmlns"=>"http://ec2.amazonaws.com/doc/2008-12-01/"}
      def create_snapshot(vol_id)
        res = @ec2.create_snapshot(:volume_id=>vol_id)
      end
      def delete_snapshot(snapshot_id)
        res = @ec2.delete_snapshot(:snapshot_id=>snapshot_id)
      end

      module MetadataService
        def query_metadata_uri(key)
          require 'open-uri'
          open("http://169.254.169.254/2008-02-01/meta-data/#{key}") { |f|
            return f.readline
          }
        end
        module_function :query_metadata_uri
        public :query_metadata_uri

        def fetch_local_attrs
          attrs = {}
          %w[instance-id instance-type local-ipv4 local-hostname public-hostname public-ipv4 ami-id].each { |key|
            rkey = key.tr('-', '_')
            attrs[rkey.to_sym]=query_metadata_uri(key)
          }
          attrs
        end
        module_function :fetch_local_attrs
        public :fetch_local_attrs
        
      end

      include MetadataService
    end

  end
end
