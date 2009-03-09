

require 'daemons/daemonize'

module Process
  # Returns +true+ the process identied by +pid+ is running.
  def running?(pid)
    Process.getpgid(pid) != -1
  rescue Errno::ESRCH
    false
  end
  module_function :running?
end


module Wakame
  module Daemonize
    # Change privileges of the process
    # to the specified user and group.
    def change_privilege(user, group=user)
      Wakame.log.info("Changing process privilege to #{user}:#{group}")

      uid, gid = Process.euid, Process.egid
      target_uid = Etc.getpwnam(user).uid
      target_gid = Etc.getgrnam(group).gid

      if uid != target_uid || gid != target_gid
        # Change process ownership
        Process.initgroups(user, target_gid)
        Process::GID.change_privilege(target_gid)
        Process::UID.change_privilege(target_uid)
      end
    rescue Errno::EPERM => e
      Wakame.log.error("Couldn't change user and group to #{user}:#{group}: #{e}")
    end

    def pid_file
      @options[:pid_file]
    end

    def pid
      File.exist?(pid_file) ? open(pid_file).read.to_i : nil
    end

    def setup_pidfile
      #raise 'Please implement pid_file() method' unless respond_to? :pid_file

      # Cleanup stale pidfile or prevent from multiple process running.
      if File.exist?(pid_file)
        if pid && Process.running?(pid)
          raise "#{pid_file} already exists, seems like it's already running (process ID: #{pid}). " +
            "Stop the process or delete #{pid_file}."
        else
          Wakame.log.info "Deleting stale PID file #{pid_file}"
          remove_pidfile
        end
      end
      
    end

    def daemonize(log_path)
      ::Daemonize.daemonize(log_path, File.basename($0.to_s))

      open(pid_file, "w") { |f| f.write(Process.pid) }
      File.chmod(0644, pid_file)

      #Signal.trap('HUP') {}
    end

    def on_restart(&blk)
      @on_restart = blk
    end

    def restart
      raise '' if @on_restart.nil?

      @on_restart.call
    end
    
    def remove_pidfile
      File.delete(pid_file) if pid_file && File.exists?(pid_file)
    end
    
  end
end
