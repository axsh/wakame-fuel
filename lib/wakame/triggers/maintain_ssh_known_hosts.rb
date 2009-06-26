module Wakame
  module Triggers
    class MaintainSshKnownHosts < Trigger
      class UpdateKnownHosts < Action
        require 'fileutils'

        def run
          host_keys = []
          ['/etc/ssh/ssh_host_rsa_key.pub', '/etc/ssh/ssh_host_dsa_key.pub'].each { |k|
            next unless File.file? k
            host_keys << File.readlines(k).join('').chomp.sub(/ host$/, '')
          }
          return if host_keys.empty?

          basedir = File.dirname(Wakame.config.ssh_known_hosts)
          FileUtils.mkpath(basedir) unless File.exist? basedir

          tmpfile = File.expand_path(File.basename(Wakame.config.ssh_known_hosts) + '.tmp', basedir)
          File.open(tmpfile, 'w') { |f|
            agent_monitor.registered_agents.each { |k, agent|
              host_keys.each { |k|
                f << "#{Wakame::Util.ssh_known_hosts_hash(agent.agent_ip)} #{k}\n"
              }
            }
          }

          FileUtils.move(tmpfile, Wakame.config.ssh_known_hosts, {:force=>true})
        end
      end


      def register_hooks
        event_subscribe(Event::AgentMonitored) { |event|
          trigger_action(UpdateKnownHosts.new)
        }

        event_subscribe(Event::AgentUnMonitored) { |event|
          trigger_action(UpdateKnownHosts.new)
        }
      end
    end
  end
end
