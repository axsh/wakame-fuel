
require 'thread'
require 'forwardable'
require 'timeout'

require 'wakame'
require 'wakame/util'

module Wakame
  module Rule
    class CancelActionError < StandardError; end

    class RuleEngine
      include Wakame
      extend Forwardable
      
      FORWARD_ATTRS=[:command_queue, :agent_monitor, :service_cluster, :master]

      attr_reader :rules, :active_jobs

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

      def initialize(service_cluster, &blk)
        @service_cluster = service_cluster
        @rules = []
        
        @active_jobs = {}
        instance_eval(&blk) if blk
      end

      def register_rule(rule)
        Wakame.log.debug("Registering rule #{rule.class}")
        rule.bind_engine(self)
        rule.register_hooks
        @rules << rule
      end


      def create_job_context(rule)
        job_id = Wakame.gen_id
        @active_jobs[job_id] = {:actions=>[], :src_rule=>rule, :created_at=>Time.now}
        job_id
      end
      
      def run_action(action)
        job_context = @active_jobs[action.job_id]
        raise "Job session is killed.: job_id=#{action.job_id}" if job_context.nil?

        EM.next_tick {

          begin
            
            EH.fire_event(Event::JobStart.new(action.job_id)) if job_context[:actions].empty?
            job_context[:actions] << action
            

            EM.defer proc {
              res = begin
                      action.status = :running
                      Wakame.log.debug("Start action : #{action.class.to_s} triggered by Rule [#{action.rule.class}]")
                      EH.fire_event(Event::ActionStart.new(action))
                      action.run
                      Wakame.log.debug("Complete action : #{action.class.to_s}")
                      EH.fire_event(Event::ActionComplete.new(action))
                    rescue => e
                      Wakame.log.error(e)
                      Wakame.log.debug("Failed action : #{action.class.to_s}")
                      EH.fire_event(Event::ActionFailed.new(action, e))
                      next e
                    ensure
                      action.status = :complete
                    end
              res
            }, proc { |res|

              job_completed = false
              if res.is_a? Exception
                if job_context[:actions].all? { |act| act.status == :complete }
                  EH.fire_event(Event::JobFailed.new(action.job_id, res))
                  job_completed = true
                end
              else
                if job_context[:actions].all? { |act| act.status == :complete }
                  EH.fire_event(Event::JobComplete.new(action.job_id))
                  job_completed = true
                end
              end

              if job_completed
                @active_jobs.delete(action.job_id)
              end
            }
          rescue => e
            Wakame.log.error(e)
          end
        }
      end

      private
      def run_action1(action)
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

    end

    class Action
      extend Forwardable
      RuleEngine::FORWARD_ATTRS.each { |i|
        def_delegator :rule, i.to_sym
      }

      attr_accessor :job_id

      attr_reader :rule

      def status
        @status ||= :ready
      end

      def status=(status)
        if @status != status
          job_context = rule.rule_engine.active_jobs[self.job_id]
          if job_context
            job_context[:actions].each { |a|
              a.notify_queue.push 1
            }
          end
        end
        @status = status
      end

      def nested_actions
        @nested_actions ||= []
      end
      alias :subactions :nested_actions

      def bind_triggered_rule(rule)
        @rule = rule
      end

      def trigger_action(subaction, opts={})
        if opts.is_a? Hash
          succ_proc = opts[:success] || opts[:succ]
          fail_proc = opts[:fail]
        end
        nested_actions << subaction
        #subaction.observers << self

        async_trigger_action(subaction, succ_proc, fail_proc)
      end

      def flush_subactions(sec=nil)
        job_context = rule.rule_engine.active_jobs[self.job_id]
        return if job_context.nil?
        
        #timeout(sec.nil? ? nil : sec) {
          until all_subactions_complete?
            #Wakame.log.debug "#{self.class} all_subactions_complete?=#{all_subactions_complete?}"
            notify_queue.shift
          end
        #}
      end

      def all_subactions_complete?
        subactions.each { |a|
          Wakame.log.debug("#{a.class}.status=#{a.status}")
          return false unless a.status == :complete && a.all_subactions_complete?
        }
        true
      end

      #def observers
      #  @observers ||= []
      #end

      def notify_queue
        @notify_queue ||= Queue.new
      end

      def run
        
      end


      private
      def sync_trigger_action(action, succ_proc, fail_proc)
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
      end

      def async_trigger_action(action, succ_proc, fail_proc)
        action.job_id = self.job_id
        action.bind_triggered_rule(self.rule)

        rule.rule_engine.run_action(action)
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

      attr_accessor :enabled
      attr_reader :rule_engine

      def agent_monitor
        @rule_engine.agent_monitor
      end

      def bind_engine(rule_engine)
        @rule_engine = rule_engine
      end

      def trigger_action(action)
        action.job_id = rule_engine.create_job_context(self)
        action.bind_triggered_rule(self)
        
        rule_engine.run_action(action)
        action.job_id
      end

      def register_hooks
      end

      protected
      def event_subscribe(event_class, &blk)
        EventHandler.subscribe(event_class) { |event|
          blk.call(event) if self.enabled 
        }
      end

    end

  end
end


module Wakame
  module Rule
    module BasicActionSet
      
      class ConditionalWait
        include ThreadImmutable

        def initialize
          @wait_queue = Queue.new
          @wait_tickets = []
          @poll_threads = []
          @event_tickets = []
        end
        
        def poll( period=5, max_retry=10, &blk)
          wticket = Wakame.gen_id
          @poll_threads << Thread.new {
            retry_count = 0

            begin
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

            rescue => e
              Wakame.log.error(e)
              @wait_queue << [false, wticket, e]
            else
              @wait_queue << [true, wticket]
            end
          }
          @poll_threads.last[:name]="#{self.class} poll"

          @wait_tickets << wticket
        end
        thread_immutable_methods :poll
        
        def wait_event(event_class, &blk)
          wticket = Wakame.gen_id
          Wakame.log.debug("#{self.class} called wait_event(#{event_class}) on thread #{Thread.current} (target_thread=#{self.target_thread?}). has_blk=#{blk}")
          ticket = EH.subscribe(event_class) { |event|
            begin
              if blk.call(event) == true
                EH.unsubscribe(ticket)
                @wait_queue << [true, wticket]
              end
            rescue => e
              Wakame.log.error(e)
              EH.unsubscribe(ticket)
              @wait_queue << [false, wticket, e]
            end
          }
          @event_tickets << ticket

          @wait_tickets << wticket
        end
        thread_immutable_methods :wait_event

        def wait_completion(tout=0)

          unless @wait_tickets.empty?
            Wakame.log.debug("#{self.class} waits for #{@wait_tickets.size} num of event(s)/polling(s).")

            timeout(((tout > 0) ? tout : nil)) {
              while @wait_tickets.size > 0 && q = @wait_queue.shift
                @wait_tickets.delete(q[1])
                
                unless q[0]
                  Wakame.log.debug("#{q[1]} failed with #{q[2]}")
                  raise q[2]
                end
              end
            }
          end
          
        ensure
          # Cleanup threads/event tickets
          @poll_threads.each { |t|
            begin
              t.kill
            rescue => e
              Wakame.log.error(e)
            end
          }
          @event_tickets.each { |t| EH.unsubscribe(t) }
        end
        thread_immutable_methods :wait_completion

      end

      def wait_condition(timeout=300, &blk)
        cond = ConditionalWait.new
        cond.bind_thread(Thread.current)

        #cond.instance_eval(&blk)
        blk.call(cond)
        
        cond.wait_completion(timeout)
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
        @vm_manipulator ||= VmManipulator.create
      end

      def start_instance(image_id, attr={})
        Wakame.log.debug("#{self.class} called start_instance(#{image_id})")
        
        attr[:user_data] = "node=agent\namqp_server=amqp://#{master.attr[:local_ipv4]}/"

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


#       def bind_agent(service_instance, &filter)
#         agent_id, agent = agent_monitor.agents.find { |agent_id, agent|
          
#           next false if agent.has_service_type?(service_instance.property.class)
#           filter.call(agent)
#         }
#         return nil if agent.nil?
#         service_instance.bind_agent(agent)
#         agent
#       end

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
        EM.barrier {
        service_cluster.each_instance(@svc_prop.class) { |svc_inst|
          next if svc_inst.status == Service::STATUS_OFFLINE
          trigger_action(StopService.new(svc_inst))
        }
        }
      end
    end      

    class PropagateInstancesAction < Action
      include BasicActionSet

      def initialize(svc_prop)
        @svc_prop = svc_prop
      end


      def run
        svc_to_start = []

        EM.barrier {
          # First, look for the service instances which are already created in the cluster. Then they will be scheduled to start the services later.
          service_cluster.each_instance(@svc_prop.class) { |svc_inst|
            svc_to_start << svc_inst if svc_inst.status != Service::STATUS_ONLINE
          }
          # The list is empty means that this action is called to propagate a new service instance instead of just starting scheduled instances.
          if svc_to_start.empty?
            svc_to_start << service_cluster.propagate(@svc_prop.class)
          end
        }

        svc_to_start.each { |svc|
          # Try to arrange agent from existing agent pool.
          if svc.agent.nil?
            EM.barrier {
              arrange_agent(svc)
            }
          end
          
          # If the agent pool is empty, will start a new VM slice.
          if svc.agent.nil?
            inst_id = start_instance(master.attr[:ami_id], @svc_prop.vm_spec.current.attrs)
            EM.barrier {
              arrange_agent(svc, inst_id)
            }
          end
          
          if svc.agent.nil?
            Wakame.log.error("Failed to arrange the agent #{svc.instance_id} (#{svc.property.class})")
            raise "Failed to arrange the agent #{@svc_prop.class}"
          end
          
          trigger_action(StartService.new(svc),{:success=>proc{
                             EH.fire_event(Event::ServicePropagated.new(svc))
                           }})
        }
      end

      private
      # Arrange an agent to be assigned
      def arrange_agent(svc, vm_inst_id=nil)
        agent = nil
        if vm_inst_id
          agent = agent_monitor.agents[vm_inst_id]
          raise "Cound not find the specified VM instance \"#{vm_inst_id}\"" if agent.nil?
          raise "Same service is running" if agent.has_service_type? @svc_prop.class
        else
          agent = agent_monitor.agents.find { |agent_id, agent|
            Wakame.log.debug "has_service_type?(#{@svc_prop.class}): #{agent.has_service_type?(@svc_prop.class)}"
            @svc_prop.vm_spec.current.satisfy?(agent) unless agent.has_service_type? @svc_prop.class
          }
          agent = agent[1] if agent
        end
        if agent
          svc.bind_agent(agent)
        end
      end

    end

    class ClusterShutdownAction < Action
      def run
        service_cluster.dg.bfs { |svc_prop|
          trigger_action(DestroyInstancesAction.new(svc_prop))
        }

        flush_subactions

        agent_monitor.agents.each { |id, agent|
          trigger_action(ShutdownVM.new(agent))
        }
      end
    end

    class ClusterResumeAction < Action
      include BasicActionSet

      def run
        if service_cluster.status == Service::ServiceCluster::STATUS_ONLINE
          Wakame.log.info("The service cluster is up & running already")
          raise CancelActionError
        end

        EM.barrier {
          service_cluster.launch
        }

        order = []
        service_cluster.dg.bfs { |svc_prop|
          order << svc_prop
        }

        order.reverse.each { |svc_prop|
          trigger_action(PropagateInstancesAction.new(svc_prop))
          flush_subactions
        }
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
        data = @agent_data[agent.agent_id] || next
        data[:load_history] << agent.attr[:uptime]
        Wakame.log.debug("Load History for agent \"#{agent.agent_id}\": " + data[:load_history].inspect )
        detect_threadshold(data, proc{
                             EH.fire_event(AgentLoadHighEvent.new(agent, data[:load_history][-1]))
                           }, proc{
                             EH.fire_event(AgentLoadNormalEvent.new(agent, data[:load_history][-1]))
                           })
        
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
        if @agent.agent_id == master.attr[:instance_id]
          Wakame.log.info("Skip to shutdown VM as the master is running on this node: #{@agent.agent_id}")
          return
        end

        vm_manipulator.stop_instance(@agent[:instance_id])
      end
    end


    class ShutdownUnusedVM < Rule
      def register_hooks
        EH.subscribe(Event::AgentPong) { |event|
          if event.agent.services.empty? &&
              Time.now - event.agent.last_service_assigned_at > Wakame.config.unused_vm_live_period &&
              event.agent.agent_id != master.attr[:instance_id]
            Wakame.log.info("Shutting the unused VM down: #{event.agent.agent.id}")
            trigger_action(ShutdownVM.new(event.agent))
          end
        }
      end
    end

    class ReloadService < Action
      include BasicActionSet

      def initialize(service_instance)
        @service_instance = service_instance
      end

      def run
        raise "Agent is not bound on this service : #{@service_instance}" if @service_instance.agent.nil?
        raise "The assigned agent for the service instance #{@service_instance.instance_id} is not online."  unless @service_instance.agent.status == AgentMonitor::Agent::STATUS_UP
        
        deploy_configuration(@service_instance)
        master.send_agent_command(Packets::Agent::ServiceReload.new(@service_instance.instance_id), @service_instance.agent.agent_id)
      end
    end

    
    class StartService < Action
      include BasicActionSet

      def initialize(service_instance)
        agent = service_instance.agent.nil?
        @service_instance = service_instance
      end

      def run
        raise "Agent is not bound on this service : #{@service_instance}" if @service_instance.agent.nil?
        raise "The assigned agent for the service instance #{@service_instance.instance_id} is not online."  unless @service_instance.agent.status == AgentMonitor::Agent::STATUS_UP
        
        # Skip to act when the service is having below status.
        if @service_instance.status == Service::STATUS_STARTING || @service_instance.status == Service::STATUS_ONLINE
          raise "Canceled as the service is being or already ONLINE: #{@service_instance.property}"
        end

        EM.barrier {
          @service_instance.status = Service::STATUS_STARTING
        }

        deploy_configuration(@service_instance)
        
        @service_instance.property.before_start(@service_instance)
        
        master.send_agent_command(Packets::Agent::ServiceStart.new(@service_instance.instance_id, @service_instance.property), @service_instance.agent.agent_id)
        
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
        raise "Agent is not bound on this service : #{@service_instance}" if @service_instance.agent.nil?
        
        # Skip to act when the service is having below status.
        if @service_instance.status == Service::STATUS_STOPPING || @service_instance.status == Service::STATUS_OFFLINE
          raise "Canceled as the service is being or already OFFLINE: #{@service_instance.property}"
        end

        EM.barrier {
          @service_instance.status = Service::STATUS_STOPPING
        }

        @service_instance.property.before_stop(@service_instance)
        
        master.send_agent_command(Packets::Agent::ServiceStop.new(@service_instance.instance_id), @service_instance.agent.agent_id)
        
        wait_condition { |cond|
          cond.wait_event(Event::ServiceOffline) { |event|
            event.instance_id == @service_instance.instance_id
          }
        }
        
        @service_instance.property.after_stop(@service_instance)

      end

    end

    class StopService_Old < Action
      include BasicActionSet

      def initialize(service_instance)
        @service_instance = service_instance
      end

      def run
        raise "Agent is not bound on this service : #{@service_instance}" if @service_instance.agent.nil?
        
        # Skip to act when the service is having below status.
        if @service_instance.status == Service::STATUS_STOPPING || @service_instance.status == Service::STATUS_OFFLINE
          raise "Canceled as the service is being or already OFFLINE: #{@service_instance.property}"
        end
        
        @service_instance.status = Service::STATUS_STOPPING
        
        @service_instance.property.before_stop(@service_instance)
        
        master.send_agent_command(Packets::Agent::ServiceStop.new(@service_instance.instance_id), @service_instance.agent.agent_id)
        
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
          svc_in_timedout_agent = service_cluster.instances.select { |k, i|
            if !i.agent.nil? && i.agent.agent_id == event.agent.agent_id
              i.status = Service::STATUS_FAIL
            end
          }
          
          update_cluster_status
        }
      end

      private
      def update_cluster_status
        onlines = []
        all_offline = false
        onlines = service_cluster.instances.select { |k, i|
          i.status == Service::STATUS_ONLINE
        }
        all_offline = service_cluster.instances.all? { |k, i|
          i.status == Service::STATUS_OFFLINE
        }
        Wakame.log.debug "online instances: #{onlines.size}, assigned instances: #{service_cluster.instances.size}"
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
