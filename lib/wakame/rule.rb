
require 'thread'
require 'sync'
require 'forwardable'

require 'wakame'

module Wakame
  module Rule
    class CancelActionError < StandardError; end

    class RuleEngine
      include Wakame
      extend Forwardable
      
      FORWARD_ATTRS=[:command_queue, :agent_monitor, :service_cluster, :master]

      attr_reader :rules, :action_queue

      def master
        service_cluster.master
      end

      def command_queue
        master.command_queue
      end

      def agent_monitor
        master.agent_monitor
      end

      def service_cluster
        @service_cluster
      end

      attr_reader :rules

      def initialize(service_cluster, &blk)
        extend(Sync_m)
        @service_cluster = service_cluster
        @rules = []
        @action_queue = Queue.new
        @processing_action = nil

        @action_threads = []
        1.times {
          @action_threads << Thread.new {
            while action = @action_queue.pop
                begin
                  if action.class == Action::NestedAction
                    log.debug("Start nested action : #{action.original_action.class.to_s}")
                    EH.fire_event(Event::ActionStart.new(action.original_action)) 
                  else
                    log.debug("Start action : #{action.class.to_s} triggered by Rule [#{action.rule.class}]")
                    EH.fire_event(Event::ActionStart.new(action)) 
                  end
                  action.run
                  if action.class == Action::NestedAction
                    log.debug("Complete nested action : #{action.original_action.class.to_s}")
                    EH.fire_event(Event::ActionComplete.new(action.original_action))
                  else
                    log.debug("Complete action : #{action.class.to_s}")
                    EH.fire_event(Event::ActionComplete.new(action))
                  end
                rescue => e
                  log.error(e)
                  EH.fire_event(Event::ActionFailed.new(action, e))
                end
            end
          }
          @action_threads.last[:name]="#{self.class} action"
        }

        instance_eval(&blk) if blk
      end

      def register_rule(rule)
        Wakame.log.debug("Registering rule #{rule.class}")
        self.synchronize {
          rule.bind_engine(self)
          rule.register_hooks
          @rules << rule
        }
      end

    end

    class Action
      extend Forwardable
      RuleEngine::FORWARD_ATTRS.each { |i|
        def_delegator :rule, i.to_sym
      }

      attr_accessor :job_id

      attr_reader :rule
      def bind_triggered_rule(rule)
        @rule = rule
      end

      def trigger_action(action, opts={})
        if opts.is_a? Hash
          succ_proc = opts[:success] || opts[:succ]
          fail_proc = opts[:fail]
        end

        cond = BasicActionSet::Lock.new
        sync_trigger_action(action, cond, succ_proc, fail_proc)
        cond
      end

      def run
      end

      private
      def sync_trigger_action(action, cond, succ_proc, fail_proc)
        action.job_id = self.job_id
        action.bind_triggered_rule(self.rule)
        Wakame.log.debug("Start nested action in SYNC: #{action.class.to_s}")
        begin
          action.run
          succ_proc.call if succ_proc
        rescue => e
          fail_proc.call if fail_proc
          raise
        end
        Wakame.log.debug("Complete nested action : #{action.class.to_s}")
      ensure
        cond.signal
      end

      def async_trigger_action(action, cond, succ_proc, fail_proc)
        rule.trigger_action(NestedAction.new(action, cond, succ_proc, fail_proc))
      end
    end

    class Action::NestedAction < Action
      def initialize(action, cond, succ_proc, fail_proc)
        @original_action = action
        @cond = cond
        @succ_proc = succ_proc
        @fail_proc = fail_proc
      end
      
      def original_action 
        @original_action
      end
      
      def job_id
        @original_action.job_id 
      end
      def job_id=(job_id)
        @original_action.job_id = job_id
      end

      def rule
        @original_action.rule
      end
      
      def bind_triggered_rule(rule)
        @original_action.bind_triggered_rule(rule)
      end
      
      def run
        @original_action.run
      ensure
        @cond.signal
      end
    end


    class Rule
      extend Forwardable
      RuleEngine::FORWARD_ATTRS.each { |i|
        def_delegator :@rule_engine, i
      }

      attr_reader :rule_engine

      def agent_monitor
        @rule_engine.agent_monitor
      end

      def bind_engine(rule_engine)
        @rule_engine = rule_engine
      end

      def trigger_action(action)
        action.job_id = Wakame.gen_id
        action.bind_triggered_rule(self)
        @rule_engine.action_queue << action
      end

      def register_hooks
      end
    end

  end
end


module Wakame
  module Rule
    module BasicActionSet
      
      class ConditionalWait
        def initialize
          @cond = ConditionVariable.new
          @mutex = Mutex.new
          # @mutex = Sync.new
          @event_count_queue = Queue.new
          @event_wait_count = 0
          @poll_threads = []
          @event_tickets = []
        end
        
        def poll( period=5, max_retry=10, &blk)
          @poll_threads << Thread.new {
            retry_count = 0
            catch(:finish) {
              while retry_count < max_retry
                start_at = Time.now
                if blk.call == true
                  throw :finish
                end
                Thread.pass
                if period > 0
                  t = Time.now - start_at
                  sleep (period - t) if period > t
                end
                retry_count += 1
              end
            }
            
            if retry_count >= max_retry
              Wakame.log.error('Over retry count')
              raise 'Over retry count'
            end
          }
          @poll_threads.last[:name]="#{self.class} poll"

        end
        
        def wait_event(event_class, &blk)
          Wakame.log.debug("#{self.class} called wait_event(#{event_class}) on thread #{Thread.current}")
          ticket = EH.subscribe(event_class) { |event|
            Wakame.log.debug("#{self.class} received event #{event.class} within wait_event() mutex.locked?=#{@mutex.locked?} on thread #{Thread.current}")
puts "@mutex.locked? in wait_event():" + @mutex.locked?.to_s
            @mutex.synchronize {
              if blk.call(event) == true
                EH.unsubscribe(ticket)
                @cond.signal
                Wakame.log.debug("signal sent from wait_event()")
                # @event_count_queue << 1
              end
            }
          }
          @event_tickets << ticket

          @event_wait_count += 1
        end

        def wait_completion
          
          @mutex.synchronize {
            @event_wait_count.times {
              Wakame.log.debug("#{self.class} is waiting for event condition processing (#{@event_wait_count}) on thread #{Thread.current}")
              @cond.wait(@mutex)
            }

            @poll_threads.each { |t|
              begin
                t.join
              rescue => e
                Wakame.log.error(e)
              end
            }
            @event_tickets.each { |t| EH.unsubscribe(t) }
          }
        end


      end

      def wait_condition(&blk)
        cond = ConditionalWait.new
        
        if block_given?
          #cond.instance_eval(&blk)
          blk.call cond
          
          cond.wait_completion
        else
          cond
        end
      end
      


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

      def vm_manipulator
        @vm_manipulator ||= Wakame.new_( Wakame.config.vm_manipulation_class )
      end

      def start_instance(instance_type, image_id)
        Wakame.log.debug("#{self.class} called start_instance(#{instance_type}, #{image_id})")
        
        user_data = "node=agent\namqp_server=amqp://#{master.attr[:local_ipv4]}/"
        res = vm_manipulator.start_instance(:image_id=>image_id, :user_data=>user_data)
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

      def start_service(service_instance)
        raise "Agent is not bound on this service : #{service_instance}" if service_instance.agent.nil?
        Wakame.log.debug("#{self.class} called start_service(#{service_instance.property.class})")

        master.send_agent_command(Packets::Agent::ServiceStart.new(service_instance.instance_id, service_instance.property), service_instance.agent.agent_id)

        wait_condition { |cond|
          cond.wait_event(Event::ServiceStatusChanged) { |event|
            Wakame.log.debug("service_instance.instance_id(=#{service_instance.instance_id}) == event.instance_id(=#{event.instance_id}) event.status=#{event.status}")
            service_instance.instance_id == event.instance_id && event.status == Service::STATUS_ONLINE
          }
        }
      end


      def bind_agent(service_instance, &filter)
        agent_id, agent = agent_monitor.agents.find { |agent_id, agent|
          
          next false if agent.has_service_type?(service_instance.property.class)
          filter.call(agent)
        }
        return nil if agent.nil?
        service_instance.bind_agent(agent)
        agent
      end

      def deploy_configuration(service_instance)
        templ = service_instance.property.template
        templ.pre_render
        templ.render(service_instance)

        agent = service_instance.agent
        src_path = templ.sync_src
        src_path.sub!('/$', '') if File.directory? src_path

        Wakame.shell.transact { 
          Wakame.log.debug("rsync -e 'ssh -i #{Wakame.config.ssh_private_key} -o \"UserKnownHostsFile #{Wakame.config.ssh_known_hosts}\"' -au #{src_path} root@#{agent.agent_ip}:#{Wakame.config.config_root}/")
          system("rsync -e 'ssh -i #{Wakame.config.ssh_private_key} -o \"UserKnownHostsFile #{Wakame.config.ssh_known_hosts}\"' -au #{src_path} root@#{agent.agent_ip}:#{Wakame.config.config_root}/" )
        }

        templ.post_render
      end
    end

    

    class DestroyInstancesAction < Action
      def initialize(svc_prop)
        @svc_prop = svc_prop
      end

      def run
        live_instance=0
        waitlist = []
        service_cluster.each_instance(@svc_prop.class) { |svc_inst|
          next if svc_inst.status == Service::STATUS_OFFLINE
          waitlist <<  trigger_action(StopService.new(svc_inst))
        }
        waitlist.each{|i| i.wait }
      end
    end      

    class PropagateInstancesAction < Action
      include BasicActionSet

      def initialize(svc_prop)
        @svc_prop = svc_prop
      end

      def run
puts "PropagateInstancesAction service_cluster.locked? (#{Thread.current}): " + service_cluster.locked?.to_s
        svc_to_start = []
        service_cluster.synchronize {
          # First, look for the service instances which are already created in the cluster. Then they will be scheduled to start the services later.
          service_cluster.each_instance(@svc_prop.class) { |svc_inst|
            svc_to_start << svc_inst if svc_inst.status != Service::STATUS_ONLINE
          }
          # The list is empty means that this action is called to propagate a new service instance instead of just starting scheduled instances.
          if svc_to_start.empty?
            svc_to_start << service_cluster.propagate(@svc_prop.class)
          end
        }
        
        waitlist = []
        svc_to_start.each { |svc|
          # Try to arrange agent from existing agent pool.
          if svc.agent.nil?
            arrange_agent(svc)
          end
          
          # If the agent pool is empty, will start a new VM slice.
          if svc.agent.nil?
            inst_id = start_instance('m1.small', master.attr[:ami_id])
            arrange_agent(svc, inst_id)
          end
          
          if svc.agent.nil?
            Wakame.log.error("Failed to arrange the agant #{svc.instance_id} (#{svc.property.class})")
            raise "Failed to arrange the agant #{@svc_prop.class}"
          end
          
          waitlist << trigger_action(StartService.new(svc),{:success=>proc{
                                         EH.fire_event(Event::ServicePropagated.new(svc))
                                       }})
        }
        
        waitlist.each {|i| i.wait }
      end

      private
      # Arrange an agent to be assigned
      def arrange_agent(svc, vm_inst_id=nil)
        agent = nil
        agent_monitor.agents.synchronize {
          if vm_inst_id
            agent = agent_monitor.agents[vm_inst_id]
            raise "Cound not find the specified VM instance \"#{vm_inst_id}\"" if agent.nil?
            raise "Same service is running" if agent.has_service_type? @svc_prop.class
          else
            agent = agent_monitor.agents.find { |agent_id, agent|
            puts "has_service_type?(#{@svc_prop.class}): #{agent.has_service_type?(@svc_prop.class)}"
              @svc_prop.eval_agent(agent) unless agent.has_service_type? @svc_prop.class
            }
            agent = agent[1] if agent
          end
        }
        if agent
          svc.bind_agent(agent)
        end
      end
    end

    class ClusterShutdownAction < Action
      def run
        waitlist = []
        service_cluster.dg.bfs { |svc_prop|
          waitlist << trigger_action(DestroyInstancesAction.new(svc_prop))
        }

        agent_monitor.agents.each { |id, agent|
          trigger_action(ShutdownVM.new(agent))
        }

        waitlist.each { |i| i.wait }
      end
    end

    class ClusterResumeAction < Action
      include BasicActionSet

      def run
        if service_cluster.status == Service::ServiceCluster::STATUS_ONLINE
          Wakame.log.info("The service cluster is up & running already")
          return
        end

        service_cluster.launch

        order = []
        service_cluster.dg.bfs { |svc_prop|
          order << svc_prop
        }
        waitlist = []
        order.reverse.each { |svc_prop|
          waitlist << trigger_action(PropagateInstancesAction.new(svc_prop))
        }
        waitlist.each { |i| i.wait }

      end

    end


    class ScaleOutWhenHighLoad < Rule
      def initialize
      end
      
      def register_hooks
        EH.subscribe(LoadHistoryMonitor::AgentLoadHighEvent) { |event|
          if service_cluster.status != Service::ServiceCluster::STATUS_ONLINE
            Wakame.log.info("Service Cluster is not online yet. Skip to scaling out")
            next
          end
          Wakame.log.debug("Got load high avg: #{event.agent.agent_id}")

          propagate_svc = nil
          event.agent.services.each { |id, svc|
            if svc.property.class == Service::Apache_APP
              puts svc.property.class.to_s
              propagate_svc = svc 
              break
            end
          }

          unless propagate_svc.nil?
            trigger_action(PropagateInstancesAction.new(propagate_svc.property)) 
          end
        }

        EH.subscribe(LoadHistoryMonitor::AgentLoadNormalEvent) { |event|
          next

          if service_cluster.status != Service::ServiceCluster::STATUS_ONLINE
            Wakame.log.info("Service Cluster is not online yet.")
            next
          end
          Wakame.log.debug("Back to normal load: #{event.agent.agent_id}")
          event.agent.services.each { |id, svc|
            trigger_action(StopService.new(svc))
          }
          
        }
      end
    end


    class LoadHistoryMonitor < Rule
      class AgentLoadHighEvent < Wakame::Event::Base
        attr_reader :agent, :load_avg
        def initialize(agent, load_avg)
          super()
          @agent = agent
          @load_avg = load_avg
        end
      end
      class AgentLoadNormalEvent < Wakame::Event::Base
        attr_reader :agent, :load_avg
        def initialize(agent, load_avg)
          super()
          @agent = agent
          @load_avg = load_avg
        end
      end
      class ServiceLoadHighEvent < Wakame::Event::Base
        attr_reader :service_property, :load_avg
        def initialize(svc_prop, load_avg)
          super()
          @service_property = svc_prop
          @load_avg = load_avg
        end
      end
      class ServiceLoadNormalEvent < Wakame::Event::Base
        attr_reader :service_property, :load_avg
        def initialize(svc_prop, load_avg)
          super()
          @service_property = svc_prop
          @load_avg = load_avg
        end
      end

      def initialize
        @agent_data = {}
        @service_data = {}
        @high_threashold = 1.2
        @history_period = 3
      end
      
      def register_hooks
        EH.subscribe(Event::AgentMonitored) { |event|
          @agent_data[event.agent.agent_id]={:load_history=>[], :last_event=>:normal}
          service_cluster.properties.each { |klass, prop|
            @service_data[klass] ||= {:load_history=>[], :last_event=>:normal}
          }
        }
        EH.subscribe(Event::AgentUnMonitored) { |event|
          @agent_data.delete(event.agent.agent_id)
        }

        EH.subscribe(Event::AgentPong) { |event|
          calc_load(event.agent)
        }
      end

      private
      def calc_load(agent)
        agent.synchronize {
          data = @agent_data[agent.agent_id] || next
          data[:load_history] << agent.attr[:uptime]
          Wakame.log.debug("Load History for agent \"#{agent.agent_id}\": " + data[:load_history].inspect )
          detect_threadshold(data, proc{
                               EH.fire_event(AgentLoadHighEvent.new(agent, data[:load_history][-1]))
                             }, proc{
                               EH.fire_event(AgentLoadNormalEvent.new(agent, data[:load_history][-1]))
                             })
        }

#         service_cluster.services.each { |id, svc|
#           next unless agent.services.keys.include? id
#           data = @service_data[svc.property.class.to_s] || next

#           data[:load_history] << agent.attr[:uptime]
#           Wakame.log.debug("Load History for service \"#{svc.property.class}\": " + data[:load_history].inspect )
#           detect_threadshold(data, proc{
#                                EH.fire_event(ServiceLoadHighEvent.new(svc.property, data[:load_history][-1]))
#                              }, proc{
#                                EH.fire_event(ServiceLoadNormalEvent.new(svc.property, data[:load_history][-1]))
#                              })
#         }

      end

      def detect_threadshold(data, when_high, when_low)
        hist = data[:load_history]
        if hist.size >= @history_period

          all_higher = hist.all? { |h| h > @high_threashold }

          if data[:last_event] == :normal && all_higher
            when_high.call
            data[:last_event] = :high
          end
          if data[:last_event] == :high && !all_higher
            when_low.call
            data[:last_event] = :normal
          end
        end
        hist.shift while hist.size > @history_period
      end

    end


    class MaintainSshKnownHosts < Rule
      class UpdateKnownHosts < Action
        def run
          host_keys = []
          ['/etc/ssh/ssh_host_rsa_key.pub', '/etc/ssh/ssh_host_dsa_key.pub'].each { |k|
            next unless File.file? k
            host_keys << File.readlines(k).join('').chomp.sub(/ host$/, '')
          }
          return if host_keys.empty?

          File.open(Wakame.config.config_tmp_root + '/known_hosts.tmp', 'w') { |f|
            agent_monitor.agents.each { |k, agent|
              host_keys.each { |k|
                f << "#{Wakame::Util.ssh_known_hosts_hash(agent.agent_ip)} #{k}\n"
              }
            }
          }

          require 'fileutils'
          FileUtils.mkpath(File.dirname(Wakame.config.ssh_known_hosts)) unless File.directory? File.dirname(Wakame.config.ssh_known_hosts)
          FileUtils.move(Wakame.config.config_tmp_root + '/known_hosts.tmp', Wakame.config.ssh_known_hosts, {:force=>true})
        end
      end


      def register_hooks
        EH.subscribe(Event::AgentMonitored) { |event|
          trigger_action(UpdateKnownHosts.new)
        }

        EH.subscribe(Event::AgentUnMonitored) { |event|
          trigger_action(UpdateKnownHosts.new)
        }
      end
    end

    class ShutdownVM < Action
      include BasicActionSet

      def initialize(agent)
        @agent = agent
      end

      def run
        if agent.agent_id == master.attr[:instance_id]
          Wakame.log.info("Skip to shutdown VM as the master is running on this node: #{agent.agent_id}")
          return
        end

        vm_manipulator.stop_instance(@agent[:instance_id])
      end
    end


    class ShutdownUnusedVM < Rule
      def register_hooks
        EH.subscribe(Event::AgentPong) { |event|
          event.agent.synchronize {
            if event.agent.services.empty? &&
                Time.now - event.agent.last_service_assigned_at > Wakame.config.unused_vm_live_period &&
                event.agent.agent_id != master.attr[:instance_id]
              Wakame.log.info("Shutting the unused VM down: #{event.agent.agent.id}")
              trigger_action(ShutdownVM.new(event.agent))
            end
          }
        }
      end
    end

    class ReloadService < Action
      include BasicActionSet

      def initialize(service_instance)
        @service_instance = service_instance
      end

      def run
        @service_instance.synchronize {
          raise "Agent is not bound on this service : #{@service_instance}" if @service_instance.agent.nil?
          raise "The assigned agent for the service instance #{@service_instance.instance_id} is not online."  unless @service_instance.agent.status == AgentMonitor::Agent::STATUS_UP

          deploy_configuration(@service_instance)
          master.send_agent_command(Packets::Agent::ServiceReload.new(@service_instance.instance_id), @service_instance.agent.agent_id)
        }
      end
    end

    
    class StartService < Action
      include BasicActionSet

      def initialize(service_instance)
        agent = service_instance.agent.nil?
        @service_instance = service_instance
      end
      def run
        @service_instance.synchronize {
          raise "Agent is not bound on this service : #{@service_instance}" if @service_instance.agent.nil?
          raise "The assigned agent for the service instance #{@service_instance.instance_id} is not online."  unless @service_instance.agent.status == AgentMonitor::Agent::STATUS_UP
          
          # Skip to act when the service is having below status.
          if @service_instance.status == Service::STATUS_STARTING || @service_instance.status == Service::STATUS_ONLINE
            raise "Canceled as the service is being or already ONLINE: #{@service_instance.property}"
          end
          
          @service_instance.status = Service::STATUS_STARTING

          deploy_configuration(@service_instance)
          
          @service_instance.property.before_start(@service_instance)

          master.send_agent_command(Packets::Agent::ServiceStart.new(@service_instance.instance_id, @service_instance.property), @service_instance.agent.agent_id)
        }

        wait_condition { |cond|
          cond.wait_event(Event::ServiceOnline) { |event|
            event.instance_id == @service_instance.instance_id
          }
        }

        @service_instance.property.after_start(@service_instance)

      end
    end

    class StopService < Action
      include BasicActionSet

      def initialize(service_instance)
        @service_instance = service_instance
      end

      def run
        @service_instance.synchronize {
          raise "Agent is not bound on this service : #{@service_instance}" if @service_instance.agent.nil?
          
          # Skip to act when the service is having below status.
          if @service_instance.status == Service::STATUS_STOPPING || @service_instance.status == Service::STATUS_OFFLINE
            raise "Canceled as the service is being or already OFFLINE: #{@service_instance.property}"
          end
          
          @service_instance.status = Service::STATUS_STOPPING

          @service_instance.property.before_stop(@service_instance)

          master.send_agent_command(Packets::Agent::ServiceStop.new(@service_instance.instance_id), @service_instance.agent.agent_id)
        }
        
        wait_condition { |cond|
          cond.wait_event(Event::ServiceOffline) { |event|
            if event.instance_id == @service_instance.instance_id
              #service_cluster.destroy(event.instance_id)
              next true
            end
          }
        }

        @service_instance.property.after_stop(@service_instance)
      end
    end

    class ReflectPropagation_LB_Subs < Rule
      class ReloadLoadBalancer < Action
        include BasicActionSet

        def run
          target_svc = {}
          service_cluster.each_instance(Service::WebCluster::HttpLoadBalanceServer) { |svc|
            Wakame.log.debug("ReloadLoadBalancer: #{svc.property.class}, status=#{svc.status}")
            next if svc.status != Service::STATUS_ONLINE

            target_svc[svc.instance_id]=1
            trigger_action(ReloadService.new(svc))
          }
          return if target_svc.empty?
          
          #wait_condition { |cond|
          #  cond.wait_event(Event::ServiceOffline) { |event|
          #    if event.instance_id == @service_instance.instance_id
          #      next true
          #    end
          #  }
          #}
        end
      end


      def initialize
      end

      def register_hooks
        EH.subscribe(Event::ServicePropagated) { |event|
          case event.service.service_property
          when Service::Apache_APP, Service::Apache_WWW
            trigger_action(MaintainSshKnownHosts::UpdateKnownHosts.new)
            trigger_action(ReloadLoadBalancer.new)
          end
        }
        
      end

    end


    class CorrectAgentAssignedService < Rule
      def register_hooks
        EH.subscribe(Event::AgentPong) { |event|
          start_svcs, stop_svcs = calc_diff(event.agent.services, event.agent.reported_services)

          start_svcs.each { |svc_id, svc|
            trigger_action(StartService.new(svc))
          }
          stop_svcs.each { |svc_id, svc|
            trigger_action(StopService.new(svc))
          }
        }
      end

      private
      def calc_diff(assigned, reported)
        a1 = assigned.values
        a2 = reported.values
        
        tobe_started = []
        tobe_stopped = []

        overwrap = a1 & a2
        assigned.each { |k,v|
          unless overwrap.included?(v)
            tobe_started << {k => v}
          end
        }
        reported.each { |k,v|
          unless overwrap.included?(v)
            tobe_stopped << {k => v}
          end
        }
        
        [tobe_started, tobe_stopped]
      end
    end
    
    
    class ClusterStatusMonitor < Rule
      def register_hooks
        EH.subscribe(Event::ServiceOnline) { |event|
          update_cluster_status
        }
        EH.subscribe(Event::ServiceOffline) { |event|
          update_cluster_status
        }

        EH.subscribe(Event::AgentTimedOut) { |event|
          service_cluster.synchronize {
            svc_in_timedout_agent = service_cluster.instances.select { |k, i|
              if !i.agent.nil? && i.agent.agent_id == event.agent.agent_id
                i.status = Service::STATUS_FAIL
              end
            }
          }
          
          update_cluster_status
        }
      end

      private
      def update_cluster_status
        onlines = []
        all_offline = false
        service_cluster.synchronize {
          onlines = service_cluster.instances.select { |k, i|
            i.status == Service::STATUS_ONLINE
          }
          all_offline = service_cluster.instances.all? { |k, i|
            i.status == Service::STATUS_OFFLINE
          }
          Wakame.log.debug "online instances: #{onlines.size}, assigned instances: #{service_cluster.instances.size}"
        }
        if service_cluster.instances.size == 0 || all_offline
          service_cluster.status = Service::ServiceCluster::STATUS_OFFLINE
        elsif onlines.size == service_cluster.instances.size
          service_cluster.status = Service::ServiceCluster::STATUS_ONLINE
        elsif onlines.size > 0
          service_cluster.status = Service::ServiceCluster::STATUS_PARTIAL_ONLINE
        end

      end
    end

    class DeployConfigAllAction < Action
      def initialize(property=nil)
        @property = property
      end
      
      def run
        service_cluster.each_instance { |svc|
          trigger_action(ReloadService.new(svc))
        }
      end
    end

    class ProcessCommand < Rule
      require 'wakame/manager/commands'
      
      def register_hooks
        EH.subscribe(Event::CommandReceived) { |event|
          case event.command
          when Manager::Commands::ClusterLaunch
            trigger_action(ClusterResumeAction.new)
            

          when Manager::Commands::ClusterShutdown
            if service_cluster.status != Service::ServiceCluster::STATUS_OFFLINE
              trigger_action(ClusterShutdownAction.new)
            end
            
          when Manager::Commands::PropagateService
            trigger_action(PropagateInstancesAction.new(event.command.property))
          when Manager::Commands::DeployConfig
            trigger_action(DeployConfigAllAction.new)
          end
        }
      end
      
    end
  end      
end
