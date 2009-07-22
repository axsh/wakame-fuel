class Wakame::Actor::MySQL
  include Wakame::Actor

  # for Amazon EC2
  def take_master_snapshot(opt_map)
    Wakame.log.debug("take_master_snapshot(opt_map)!!!")
    Wakame.log.debug(opt_map)

    aws_access_key  = opt_map[:aws_access_key]
    aws_secret_key  = opt_map[:aws_secret_key]
    master_ip       = opt_map[:master_ip]
    master_port     = opt_map[:master_port]
    ebs_volume      = opt_map[:master_ebs_volume]
    repl_user       = opt_map[:repl_user] # 'wakame-repl'
    repl_pass       = opt_map[:repl_pass] # 'wakame-slave'

    mysql_client = "/usr/bin/mysql -h#{master_ip} -P#{master_port} -u#{repl_user} -p#{repl_pass} -s"

    Wakame.log.debug("Wakame::Actor::Mysql.take_master_snapshot aws_access_key:#{aws_access_key} aws_secret_key:#{aws_secret_key}")
    Wakame::Util.exec("echo 'FLUSH TABLES WITH READ LOCK;' | #{mysql_client}")
    master_status = `echo show master status | #{mysql_client}`.to_s.split(/\t/)[0..1]

    # mysql/data/master.info
    master_infos = []
    master_infos << 14
    master_infos << master_status[0]
    master_infos << master_status[1]
    master_infos << master_ip
    master_infos << repl_user
    master_infos << repl_pass
    master_infos << master_port
    master_infos << 60
    master_infos << 0
    master_infos << ""
    master_infos << ""
    master_infos << ""
    master_infos << ""
    master_infos << ""
    master_infos << ""
    Wakame.log.debug(master_infos)

    master_info = File.expand_path('master.info', opt_map[:master_mysqld_datadir])
    Wakame.log.debug("master_info : #{master_info}")
    file = File.new(master_info, "w")
    file.puts(master_infos.join("\n"))
    file.chmod(0664)
    file.close

    require 'fileutils'
    FileUtils.chown('mysql', 'mysql', master_info)

    Wakame::Util.exec("/bin/sync")
    sleep 1.0

    # あとはsnapshot作成か
    # - MySQL_Masterがマウントしているvolume-idが必要
    # - MySQL_Masterのインスタンス情報が必要
    require 'right_aws'
    ec2 = RightAws::Ec2.new(aws_access_key, aws_secret_key)
    volume_map = ec2.describe_volumes([ebs_volume])[0]
    Wakame.log.debug("volume_map>>>>>")
    Wakame.log.debug(volume_map)

    Wakame.log.debug("describe_volume(#{ebs_volume}): #{volume_map.inspect}")
    if volume_map[:aws_status] == 'in-use'
      # Nothin to be done
      Wakame.log.debug("# Nothin to be done")
    else
      Wakame.log.debug("The EBS volume(slave) is not ready to attach: #{ebs_volume}")
      return
    end

    # create_snapshot
    snapshot_map = ec2.create_snapshot(ebs_volume)
    Wakame.log.debug("create_snapshot>>>>>")
    Wakame.log.debug(snapshot_map)
    # describe_snapshot
    16.times do |i|
      snapshot_map = ec2.describe_snapshots([snapshot_map[:aws_id]])[0]
      Wakame.log.debug("describe_snapshot(#{i})>>>>>")
      Wakame.log.debug(snapshot_map)
      if snapshot_map[:aws_status] == "completed"
        Wakame::Util.exec("/bin/sync")
        break
      end
      sleep 1.0
    end

    # unlock
    Wakame::Util.exec("echo 'UNLOCK TABLES;' | #{mysql_client}")

    # create volume from snapshot
    #     #  ec2.create_volume('snap-000000', 10, zone) #=>
    created_volume_from_snapshot_map = ec2.create_volume(snapshot_map[:aws_id], volume_map[:aws_size], volume_map[:zone])
    Wakame.log.debug("create_volume_from_snapshot>>>>>")
    Wakame.log.debug(created_volume_from_snapshot_map)
    # Hash: {:aws_created_at=>Mon Jul 20 07:25:27 UTC 2009, :zone=>"us-east-1d", :aws_status=>"creating", :snapshot_id=>"snap-453eed2c", :aws_id=>"vol-afe40cc6", :aws_size=>1}
    # describe_volume
    16.times do |i|
      volume_map = ec2.describe_volumes([created_volume_from_snapshot_map[:aws_id]])[0]
      Wakame.log.debug("describe_volume(#{i})>>>>>")
      Wakame.log.debug(volume_map)
      if volume_map[:aws_status] == "available"
        Wakame::Util.exec("/bin/sync")
        break
      end
      sleep 1.0
    end

    # delete_snapshot
    delete_map = ec2.delete_snapshot(snapshot_map[:aws_id])
    Wakame.log.debug("delete_map>>>>>")
    Wakame.log.debug(delete_map)

    Wakame.log.debug("attach target >>>")
    Wakame.log.debug(volume_map)

    # attach_volume
    attach_volume_map = ec2.attach_volume(volume_map[:aws_id], agent.agent_id, opt_map[:ebs_device])
    Wakame.log.debug("attach_volume_map>>>>>")
    Wakame.log.debug(attach_volume_map)
    # describe_volume
    16.times do |i|
      volume_map = ec2.describe_volumes([attach_volume_map[:aws_id]])[0]
      Wakame.log.debug("describe_volume(#{i})>>>>>")
      Wakame.log.debug(volume_map)
      if volume_map[:aws_status] == "in-use"
        Wakame::Util.exec("/bin/sync")
        break
      end
      sleep 1.0
    end

=begin
    # detach_volume
    sleep 3.0 # :(
    detach_volume_map = ec2.detach_volume(volume_map[:aws_id], agent.agent_id, opt_map[:ebs_device])
    Wakame.log.debug("detach_volume_map>>>>>")
    Wakame.log.debug(detach_volume_map)
    # describe_volume
    16.times do |i|
      volume_map = ec2.describe_volumes([detach_volume_map[:aws_id]])[0]
      Wakame.log.debug("describe_volume(#{i})>>>>>")
      Wakame.log.debug(volume_map)
      if volume_map[:aws_status] == "available"
        Wakame::Util.exec("/bin/sync")
        break
      end
      sleep 1.0
    end
=end

  end
end
