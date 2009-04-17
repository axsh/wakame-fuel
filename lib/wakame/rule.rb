
require 'thread'
require 'forwardable'
require 'timeout'

require 'wakame'
require 'wakame/util'

module Wakame
  module Rule
    class CancelActionError < StandardError; end
    class CancelBroadcast < StandardError; end

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
        @job_history = []
        instance_eval(&blk) if blk
      end

      def register_rule(rule)
        Wakame.log.debug("Registering rule #{rule.class}")
        rule.bind_engine(self)
        rule.register_hooks
        @rules << rule
      end

      def create_job_context(rule, root_action)
        root_action.job_id = job_id = Wakame.gen_id

        @active_jobs[job_id] = {
          :job_id=>job_id,
          :src_rule=>rule,
          :create_at=>Time.now,
          :start_at=>nil, 
          :complete_at=>nil,
          :root_action=>root_action
        }
      end

      def cancel_action(job_id)
        job_context = @active_jobs[job_id]
        if job_context.nil?
          Wakame.log.warn("JOB ID #{job_id} was not running.")
          return
        end
        
        return if job_context[:complete_at]

        root_act = job_context[:root_action]

        walk_subactions = proc { |a|
          if a.status == :running && (a.target_thread && a.target_thread.alive?)
            Wakame.log.debug "Raising CancelBroadcast exception: #{a.class} #{a.target_thread}(#{a.target_thread.status}), current=#{Thread.current}"
            # Broadcast the special exception to all
            a.target_thread.raise(CancelBroadcast)
            # IMPORTANT: Ensure the worker thread to handle the exception.
            #Thread.pass
          end
          a.subactions.each { |n|
            walk_subactions.call(n)
          }
        }

        begin
          Thread.critical = true
          walk_subactions.call(root_act)
        ensure
          Thread.critical = false
            # IMPORTANT: Ensure the worker thread to handle the exception.
            Thread.pass
        end
      end

      def run_action(action)
        job_context = @active_jobs[action.job_id]
        raise "The job session is killed.: job_id=#{action.job_id}" if job_context.nil?

        EM.next_tick {

          begin
            
            if job_context[:start_at].nil?
              job_context[:start_at] = Time.new
              EH.fire_event(Event::JobStart.new(action.job_id))
            end

            EM.defer proc {
              res = nil
              begin
                action.bind_thread(Thread.current)
                action.status = :running
                Wakame.log.debug("Start action : #{action.class.to_s} triggered by Rule [#{action.rule.class}]")
                EH.fire_event(Event::ActionStart.new(action))
                begin
                  action.run
                ensure
                  action.status = :complete
                end
                Wakame.log.debug("Complete action : #{action.class.to_s}")
                EH.fire_event(Event::ActionComplete.new(action))
              rescue CancelBroadcast => e
                Wakame.log.info("Received cancel signal: #{e}")
                EH.fire_event(Event::ActionFailed.new(action, e))
                res = e
              rescue => e
                Wakame.log.debug("Failed action : #{action.class.to_s} due to #{e}")
                Wakame.log.error(e)
                EH.fire_event(Event::ActionFailed.new(action, e))
                # Escalate the cancelation to parents.
                action.notify(e)
                # Force cancel the current job when the root action ignored the elevated exception.
                if action === job_context[:root_action]
                  cancel_action(job_context[:job_id]) #rescue Wakame.log.error($!)
                end
                res = e
              ensure
                action.bind_thread(nil)
              end

              res
            }, proc { |res|
              unless @active_jobs.has_key?(job_context[:job_id])
                next
              end
              
              jobary = []
              job_context[:root_action].walk_subactions {|a| jobary << a }
              p jobary.collect{|a| {a.class.to_s=>a.status}}

              job_completed = false
              if res.is_a?(Exception)
                if jobary.all? { |act| act.status == :complete }
                  Wakame.log.info("Canceled all actions in JOB ID #{job_context[:job_id]}.") if res.is_a?(CancelBroadcast) 
                  EH.fire_event(Event::JobFailed.new(action.job_id, res))
                  job_context[:exception]=res
                  job_completed = true
                end
              else
                if jobary.all? { |act| act.status == :complete }
                  EH.fire_event(Event::JobComplete.new(action.job_id))
                  job_completed = true
                end
              end

              if job_completed
                job_context[:complete_at]=Time.now
                @job_history << job_context
                @active_jobs.delete(job_context[:job_id])
              end
            }
          rescue => e
            Wakame.log.error(e)
          end
        }
      end

    end


    class Action
      extend Forwardable
      RuleEngine::FORWARD_ATTRS.each { |i|
        def_delegator :rule, i.to_sym
      }
      include AttributeHelper
      include ThreadImmutable

      def_attribute :job_id
      def_attribute :status, :ready
      def_attribute :parent_action

      attr_reader :rule

      def status=(status)
        if @status != status
          @status = status
          # Notify to observers after updating the attribute
          notify
        end
        @status
      end
      thread_immutable_methods :status=


      def subactions
        @subactions ||= []
      end

      def bind_triggered_rule(rule)
        @rule = rule
      end

      def trigger_action(subaction, opts={})
        if opts.is_a? Hash
          succ_proc = opts[:success] || opts[:succ]
          fail_proc = opts[:fail]
        end
        subactions << subaction
        subaction.parent_action = self
        #subaction.observers << self

        async_trigger_action(subaction, succ_proc, fail_proc)
      end

      def flush_subactions(sec=nil)
        job_context = rule.rule_engine.active_jobs[self.job_id]
        return if job_context.nil?
        
        timeout(sec.nil? ? nil : sec) {
          until all_subactions_complete?
            #Wakame.log.debug "#{self.class} all_subactions_complete?=#{all_subactions_complete?}"
            src = notify_queue.deq
            # Exit the current action when a subaction notified exception.
            if src.is_a?(Exception)
              raise src
            end
            #Wakame.log.debug "#{self.class} notified by #{src.class}, all_subactions_complete?=#{all_subactions_complete?}"
          end
        }
      end

      def all_subactions_complete?
        subactions.each { |a|
          #Wakame.log.debug("#{a.class}.status=#{a.status}")
          return false unless a.status == :complete && a.all_subactions_complete?
        }
        true
      end

      def notify_queue
        @notify_queue ||= Queue.new
      end

      def notify(src=nil)
        #Wakame.log.debug("#{self.class}.notify() has been called")
        src = self if src.nil?
        notify_queue.clear if notify_queue.size > 0
        notify_queue.enq(src) #if notify_queue.num_waiting > 0
        unless parent_action.nil?
          parent_action.notify(src)
        end
      end


      def walk_subactions(&blk)
        blk.call(self)
        self.subactions.each{ |a|
          a.walk_subactions(&blk)
        }
      end


      def run
        raise NotImplementedError
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


    class Rule
      extend Forwardable
      RuleEngine::FORWARD_ATTRS.each { |i|
        def_delegator :@rule_engine, i
      }

      include FilterChain
      include AttributeHelper

      def_attribute :enabled, true

      attr_reader :rule_engine

      def agent_monitor
        @rule_engine.agent_monitor
      end

      def bind_engine(rule_engine)
        @rule_engine = rule_engine
      end

      def trigger_action(action)
        found = rule_engine.active_jobs.find { |id, job|
          job[:src_rule].class == self.class
        }

        if found
          Wakame.log.warn("#{self.class}: Exisiting Job \"#{found[:job_id]}\" was kicked from this rule and it's still running. Skipping...")
          raise CancelActionError
        end

        rule_engine.create_job_context(self, action)
        action.bind_triggered_rule(self)
        
        rule_engine.run_action(action)
        action.job_id
      end

      def register_hooks
      end

      protected
      def event_subscribe(event_class, &blk)
        EventHandler.subscribe(event_class) { |event|
          begin
            run_filter(self)
            blk.call(event) if self.enabled 
          rescue => e
            Wakame.log.error(e)
          end
        }
      end

    end

  end
end


module Wakame
  module Rule
    module BasicActionSet
      
      class ConditionalWait
        class TimeoutError < StandardError; end
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

            timeout(((tout > 0) ? tout : nil), TimeoutError) {
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


      def deploy_configuration(service_instance)
        Wakame.log.debug("Begin: #{self.class}.deploy_configuration(#{service_instance.property.class})")
        templ = service_instance.property.template
        templ.pre_render
        templ.render(service_instance)

        agent = service_instance.agent
        src_path = templ.sync_src
        src_path.sub!('/$', '') if File.directory? src_path

        Wakame.log.debug("rsync -e 'ssh -i #{Wakame.config.ssh_private_key} -o \"UserKnownHostsFile #{Wakame.config.ssh_known_hosts}\"' -au #{src_path} root@#{agent.agent_ip}:#{Wakame.config.config_root}/")
        system("rsync -e 'ssh -i #{Wakame.config.ssh_private_key} -o \"UserKnownHostsFile #{Wakame.config.ssh_known_hosts}\"' -au #{src_path} root@#{agent.agent_ip}:#{Wakame.config.config_root}/" )

        templ.post_render
        Wakame.log.debug("End: #{self.class}.deploy_configuration(#{service_instance.property.class})")
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



    class DestroyInstancesAction < Action
      def initialize(svc_prop)
        @svc_prop = svc_prop
      end

      def run
        svc_to_stop=[]

        EM.barrier {
          online_svc = []
          service_cluster.each_instance(@svc_prop.class) { |svc_inst|
            if svc_inst.status == Service::STATUS_ONLINE
              online_svc << svc_inst
            end
          }

          if @svc_prop.instance_count < online_svc.size
            online_svc.delete_if { |svc|
              svc.agent.agent_id == master.attr[:instance_id]
            }
        
            (online_svc.size - @svc_prop.instance_count).times {
              svc_to_stop << online_svc.shift
            }
            Wakame.log.debug("#{self.class}: online_svc.size=#{online_svc.size}, svc_to_stop.size=#{svc_to_stop.size}")
          end
        }

        svc_to_stop.each { |svc_inst|
          trigger_action(StopService.new(svc_inst))
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
          online_svc = []
          service_cluster.each_instance(@svc_prop.class) { |svc_inst|
            if svc_inst.status == Service::STATUS_ONLINE || svc_inst.status == Service::STATUS_STARTING
              online_svc << svc_inst
            else
              svc_to_start << svc_inst
            end
          }

          # The list is empty means that this action is called to propagate a new service instance instead of just starting scheduled instances.
          if @svc_prop.instance_count > online_svc.size + svc_to_start.size
            Wakame.log.debug("#{self.class}: @svc_prop.instance_count - online_svc.size=#{@svc_prop.instance_count - online_svc.size}")
            (@svc_prop.instance_count - (online_svc.size + svc_to_start.size)).times {
              svc_to_start << service_cluster.propagate(@svc_prop.class)
            }
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
          
          #trigger_action(StartService.new(svc),{:success=>proc{
          #                   EH.fire_event(Event::ServicePropagated.new(svc))
          #                 }})
          trigger_action(StartService.new(svc))
        }
      end

      private
      # Arrange an agent for the paticular service instance which does not have agent.
      def arrange_agent(svc, vm_inst_id=nil)
        agent = nil
        if vm_inst_id
          agent = agent_monitor.agents[vm_inst_id]
          raise "Cound not find the specified VM instance \"#{vm_inst_id}\"" if agent.nil?
          raise "Same service is running" if agent.has_service_type? @svc_prop.class
        else
          agent_monitor.each_online { |ag|
            Wakame.log.debug "has_service_type?(#{@svc_prop.class}): #{ag.has_service_type?(@svc_prop.class)}"
            if test_agent_candidate(@svc_prop, ag)
              agent = ag
              break
            end
          }
        end
        if agent
          svc.bind_agent(agent)
        end
      end

    end

    class ClusterShutdownAction < Action
      def run
        levels = service_cluster.dg.levels

        levels.reverse.each { |lv|
          lv.each { |svc_prop|
            service_cluster.each_instance(svc_prop.class) { |svc_inst|
              trigger_action(StopService.new(svc_inst))
            }
          }
          flush_subactions
        }

        agent_monitor.agents.each { |id, agent|
          trigger_action(ShutdownVM.new(agent))
        }
      end
    end

    class ClusterLaunchAction < Action
      include BasicActionSet

      def run
        if service_cluster.status == Service::ServiceCluster::STATUS_ONLINE
          Wakame.log.info("The service cluster is up & running already")
          raise CancelActionError
        end

        EM.barrier {
          service_cluster.launch
        }

        Wakame.log.debug("ClushterLaunchAction: Resource Launch Order: " + service_cluster.dg.levels.collect {|lv| '['+ lv.collect{|prop| "#{prop.class}" }.join(', ') + ']' }.join(', '))

        service_cluster.dg.levels.each { |lv|
          lv.each { |svc_prop|
            trigger_action(PropagateInstancesAction.new(svc_prop))
          }
          flush_subactions
          Wakame.log.debug("#{self.class}: DG level next")
        }
      end

    end


    class ScaleOutWhenHighLoad < Rule
      def initialize
      end
      
      def register_hooks
        event_subscribe(LoadHistoryMonitor::AgentLoadHighEvent) { |event|
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

        event_subscribe(LoadHistoryMonitor::AgentLoadNormalEvent) { |event|
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
        event_subscribe(Event::AgentMonitored) { |event|
          @agent_data[event.agent.agent_id]={:load_history=>[], :last_event=>:normal}
          service_cluster.properties.each { |klass, prop|
            @service_data[klass] ||= {:load_history=>[], :last_event=>:normal}
          }
        }
        event_subscribe(Event::AgentUnMonitored) { |event|
          @agent_data.delete(event.agent.agent_id)
        }

        event_subscribe(Event::AgentPong) { |event|
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
        event_subscribe(Event::AgentMonitored) { |event|
          trigger_action(UpdateKnownHosts.new)
        }

        event_subscribe(Event::AgentUnMonitored) { |event|
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
        event_subscribe(Event::AgentPong) { |event|
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

        # Skip to act when the service is having below status.
        #if @service_instance.status == Service::STATUS_STARTING || @service_instance.status == Service::STATUS_ONLINE
        #  raise "Canceled as the service is being or already ONLINE: #{@service_instance.property}"
        #end
        
        master.send_agent_command(Packets::Agent::ServiceReload.new(@service_instance.instance_id), @service_instance.agent.agent_id)
      end
    end


    class MigrateServiceAction < Action
      include BasicActionSet

      def initialize(service_instance, dest_agent=nil)
        @service_instance = service_instance
        @destination_agent = dest_agent
      end

      def run
        raise CancelActionError if @service_instance.status == Service::STATUS_MIGRATING

        EM.barrier {
          @service_instance.status = Service::STATUS_MIGRATING
        }
        prop = @service_instance.property
        if prop.duplicable
          clone_service(prop)
          flush_subactions
          trigger_action(StopService.new(@service_instance))
        else
          
          trigger_action(StopService.new(@service_instance))
          flush_subactions
          clone_service(prop)
        end
        flush_subactions
      end

      private
      def clone_service(resource)
        new_svc = nil
        EM.barrier {
          new_svc = service_cluster.propagate(resource, true)
        }

        agent = @destination_agent
        if agent.nil?
          EM.barrier {
            agent = arrange_agent(resource)
          }
          if agent.nil?
            inst_id = start_instance(master.attr[:ami_id], resource.vm_spec.current.attrs)
            agent = agent_monitor.agents[inst_id]
          end
        end

        if !(agent && test_agent_candidate(resource, agent))
          raise "Found confiction(s) when the agent is assigned to sevice: #{resource} #{agent} "
        end

        EM.barrier {
          new_svc.bind_agent(agent)
        }

        trigger_action(StartService.new(new_svc))
        new_svc
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
        
        @service_instance.property.before_start(@service_instance, self)
        
        master.send_agent_command(Packets::Agent::ServiceStart.new(@service_instance.instance_id, @service_instance.property), @service_instance.agent.agent_id)
        
        wait_condition { |cond|
          cond.wait_event(Event::ServiceOnline) { |event|
            event.instance_id == @service_instance.instance_id
          }
        }
        
        @service_instance.property.after_start(@service_instance, self)

        EM.barrier {
          Wakame.log.debug("Child nodes: #{@service_instance.property.class}: " + service_cluster.dg.children(@service_instance.property.class).inspect)
          service_cluster.dg.children(@service_instance.property.class).each { |svc_prop|
            Wakame.log.debug("Spreading DG child changed: #{@service_instance.property.class} -> #{svc_prop.class}")
            trigger_action(CallChildChangeAction.new(svc_prop))
          }
        }

      end
    end

    class CallChildChangeAction < Action
      include BasicActionSet

      def initialize(resource)
        @resource = resource
        #@parent_instance = parent_instance
      end
      
      def run
        Wakame.log.debug("CallChildChangeAction: run: #{@resource.class}")
        service_cluster.each_instance(@resource.class) { |svc_inst|
          next if svc_inst.status != Service::STATUS_ONLINE
          @resource.on_parent_changed(self, svc_inst)
        }
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
          raise CancelActionError, "Canceled as the service is being or already OFFLINE: #{@service_instance.property}"
        end

        EM.barrier {
          @service_instance.status = Service::STATUS_STOPPING
        }
        
        EM.barrier {
          Wakame.log.debug("Child nodes: #{@service_instance.property.class}: " + service_cluster.dg.children(@service_instance.property.class).inspect)
          service_cluster.dg.children(@service_instance.property.class).each { |svc_prop|
            trigger_action(CallChildChangeAction.new(svc_prop))
          }
        }

        flush_subactions()

        @service_instance.property.before_stop(@service_instance, self)
        
        master.send_agent_command(Packets::Agent::ServiceStop.new(@service_instance.instance_id), @service_instance.agent.agent_id)
        
        wait_condition { |cond|
          cond.wait_event(Event::ServiceOffline) { |event|
            event.instance_id == @service_instance.instance_id
          }
        }
        
        @service_instance.property.after_stop(@service_instance, self)

        EM.barrier {
          service_cluster.destroy(@service_instance.instance_id)
        }
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

    class AfterClusterStart < Rule
      append_filter { |rule|
        rule.service_cluster.status == Service::ServiceCluster::STATUS_ONLINE
      }
    end

    class ClusterStatusMonitor < Rule
      def register_hooks
        event_subscribe(Event::ServiceOnline) { |event|
          update_cluster_status
        }
        event_subscribe(Event::ServiceOffline) { |event|
          update_cluster_status
        }

        event_subscribe(Event::AgentTimedOut) { |event|
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


    class InstanceCountUpdate < AfterClusterStart
      def register_hooks
        event_subscribe(Event::InstanceCountChanged) { |event|
          next if service_cluster.status == Service::ServiceCluster::STATUS_OFFLINE

          if event.increased?
            Wakame.log.debug("#{self.class}: trigger PropagateInstancesAction.new(#{event.resource.class})")
            trigger_action(PropagateInstancesAction.new(event.resource))
          elsif event.decreased?
            Wakame.log.debug("#{self.class}: trigger DestroyInstancesAction.new(#{event.resource.class})")
            trigger_action(DestroyInstancesAction.new(event.resource))
          end
        }
      end
    end


    class ProcessCommand < Rule
      require 'wakame/manager/commands'
      
      def register_hooks
        event_subscribe(Event::CommandReceived) { |event|
          case event.command
          when Manager::Commands::ClusterLaunch
            trigger_action(ClusterLaunchAction.new)

          when Manager::Commands::ClusterShutdown
            if service_cluster.status != Service::ServiceCluster::STATUS_OFFLINE
              trigger_action(ClusterShutdownAction.new)
            end
            
          when Manager::Commands::PropagateService
            trigger_action(PropagateInstancesAction.new(event.command.property))
          when Manager::Commands::MigrateService
            trigger_action(MigrateServiceAction.new(event.command.service_instance, 
                                                    event.command.agent
                                                    ))
          when Manager::Commands::DeployConfig
            trigger_action(DeployConfigAllAction.new)
          end
        }
      end
      
    end
  end      
end
