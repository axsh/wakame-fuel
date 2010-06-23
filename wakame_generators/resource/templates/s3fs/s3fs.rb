class S3fs < Wakame::Service::Resource

  property :s3fs_bucket
  property :s3fs_path
  property :s3fs_mount_option, {:default=>'-o use_cache=/tmp'}

  def start(svc, action)
    action.actor_request(svc.cloud_host.agent_id,
                         '/s3fs/mount', self.s3fs_bucket, self.s3fs_path, self.s3fs_mount_option) { |req|
      req.wait
      Wakame.log.debug("s3fs mount: #{self.s3fs_bucket} on #{self.s3fs_path}")
    }
    svc.update_monitor_status(Wakame::Service::STATUS_ONLINE)
  end
  
  def stop(svc, action)
    action.actor_request(svc.cloud_host.agent_id,
                         '/s3fs/umount', self.s3fs_path) { |req|
      req.wait
      Wakame.log.debug("s3fs umount: #{self.s3fs_bucket} on #{self.s3fs_path}")
    }
    svc.update_monitor_status(Wakame::Service::STATUS_OFFLINE)
  end
end
