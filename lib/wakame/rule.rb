
require 'thread'
require 'forwardable'
require 'timeout'

require 'wakame/util'

module Wakame
  module Rule
    module BasicActionSet
      class Lock
        def initialize
          @mutex = Mutex.new
          @cond = ConditionVariable.new
        end

        def signal
          @mutex.synchronize {
            @cond.signal
          }
        end

        def wait(&blk)
          if blk.nil?
            i=0
            blk = proc {
              i += 1
              i > 1 ? true : false
            }
          end
          @mutex.synchronize {
            @cond.wait(@mutex) while blk.call
          }
        end
      end

      class MockLock < Lock
        def signal
        end

        def wait(&blk)
        end
      end


      def wait_lock 
        Lock.new
      end

      def start_instance(image_id, attr={})
        Wakame.log.debug("#{self.class} called start_instance(#{image_id})")
        
        attr[:user_data] = "node=agent\namqp_server=amqp://#{master.attr[:local_ipv4]}/"
        Wakame.log.debug("user_data: #{attr[:user_data]}")
        vm_manipulator = VmManipulator.create
        res = vm_manipulator.start_instance(image_id, attr)
        inst_id = res[:instance_id]

        wait_condition { | cond |
          cond.wait_event(Event::AgentMonitored) { |event|
            event.agent.attr[:instance_id] == inst_id
          }
          
          cond.poll(5, 100) {
            vm_manipulator.check_status(inst_id, :online)
          }
        }

        inst_id
      end

      def self.deploy_configuration(service_instance)
        Wakame.log.debug("Begin: #{self}.deploy_configuration(#{service_instance.property.class})")

        begin
          tmpl = Wakame::Template.new(service_instance)
          tmpl.render_config
          
          agent = service_instance.agent
          src_path = tmpl.tmp_basedir.dup
          src_path.sub!('/$', '') if File.directory? src_path
          
          dest_path = File.expand_path("tmp/config/" + File.basename(tmpl.basedir), service_instance.agent.root_path)
          Util.exec("rsync -e 'ssh -i #{Wakame.config.ssh_private_key} -o \"UserKnownHostsFile #{Wakame.config.ssh_known_hosts}\"' -au #{src_path}/ root@#{agent.agent_ip}:#{dest_path}")
          #Util.exec("rsync -au #{src_path}/ #{dest_path}")
          
        ensure
          tmpl.cleanup if tmpl
        end

        Wakame.log.debug("End: #{self}.deploy_configuration(#{service_instance.property.class})")
      end

      def test_agent_candidate(svc_prop, agent)
        return false if agent.has_service_type?(svc_prop.class)
        svc_prop.vm_spec.current.satisfy?(agent) 
      end
      # Arrange an agent for the paticular service instance from agent pool.
      def arrange_agent(svc_prop)
        agent = nil
        agent_monitor.each_online { |ag|
          if test_agent_candidate(svc_prop, ag)
            agent = ag
            break
          end
        }
        agent = agent[1] if agent

        agent
      end

    end


  end      
end
