#!/usr/bin/ruby

require 'rubygems'

require 'wakame'
require 'wakame/packets'
require 'wakame/service'
require 'wakame/queue_declare'
require 'wakame/vm_manipulator'

module Wakame

  module Manager
    attr_accessor :master

    def init
    end
    
    def start
    end
    
    def stop
    end
    
    def reload
    end
    
    def terminate
    end
  end
  

  class AgentMonitor
    include Manager
    include ThreadImmutable

    def init
      @agent_timeout = 31.to_f
      @agent_kill_timeout = @agent_timeout * 2
      @gc_period = 20.to_f

      Service::AgentPool.reset

      # GC event trigger for agent timer & status
      @agent_timeout_timer = EM::PeriodicTimer.new(@gc_period) {
        StatusDB.pass {
          #Wakame.log.debug("Started agent GC : agents.size=#{@registered_agents.size}")
          [self.agent_pool.group_active.keys, self.agent_pool.group_observed.keys].flatten.uniq.each { |agent_id|
            agent = Service::Agent.find(agent_id)
            #next if agent.status == Service::Agent::STATUS_OFFLINE
            
            diff_time = Time.now - agent.last_ping_at_time
            #Wakame.log.debug "AgentMonitor GC : #{agent_id}: #{diff_time}"
            if diff_time > @agent_timeout.to_f
              agent.update_status(Service::Agent::STATUS_TIMEOUT)
            end
            
            if diff_time > @agent_kill_timeout.to_f
              agent_pool.unregister(agent)
            end
          }
          
          #Wakame.log.debug("Finished agent GC")
        }
      }
      
      
      master.add_subscriber('registry') { |data|
        data = eval(data)
        
        StatusDB.pass {
          agent_id = data[:agent_id]
          
          agent = agent_pool.create_or_find(agent_id)
          
          case data[:class_type]
          when 'Wakame::Packets::Register'
            agent.root_path = data[:root_path]
            agent.vm_attr = data[:attrs]
            agent.save
            agent_pool.register(agent)
          when 'Wakame::Packets::UnRegister'
            agent_pool.unregister(agent)
          end
        }

      }

      master.add_subscriber('ping') { |data|
        ping = eval(data)
        # Skip the old ping responses before starting master node.
        next if Time.parse(ping[:responded_at]) < master.started_at

        # Variable update function for the common members
        set_report_values = proc { |agent|
          agent.last_ping_at = ping[:responded_at]
          agent.vm_attr = ping[:attrs]

          agent.renew_reported_services(ping[:services])
          agent.save

          agent.update_status(Service::Agent::STATUS_ONLINE)
        }
        
        StatusDB.pass { 
          agent = Service::Agent.find(ping[:agent_id])
          if agent.nil?
            agent = Service::Agent.new
            agent.id = ping[:agent_id]
            
            set_report_values.call(agent)

            agent_pool.register_as_observed(agent)
          else
            set_report_values.call(agent)
          end
          
          EventDispatcher.fire_event(Event::AgentPong.new(agent))
        }
      }
      
      master.add_subscriber('agent_event') { |data|
        response = eval(data)
        StatusDB.pass {
          case response[:class_type]
          when 'Wakame::Packets::StatusCheckResult'
            svc_inst = Service::ServiceInstance.find(response[:svc_id])
            if svc_inst
              svc_inst.monitor_status = response[:status]
              svc_inst.save
            else
              Wakame.log.error("#{self.class}: Unknown service ID: #{response[:svc_id]}")
            end
          when 'Wakame::Packets::ServiceStatusChanged'
            svc_inst = Service::ServiceInstance.find(response[:svc_id])
            if svc_inst
              response_time = Time.parse(response[:responded_at])
              svc_inst.update_status(response[:new_status], response_time, response[:fail_message])
            end
          when 'Wakame::Packets::ActorResponse'
            case response[:status]
            when Actor::STATUS_RUNNING
              EventDispatcher.fire_event(Event::ActorProgress.new(response[:agent_id], response[:token], 0))
            when Actor::STATUS_FAILED
              EventDispatcher.fire_event(Event::ActorComplete.new(response[:agent_id], response[:token], response[:status], nil))
            else
              EventDispatcher.fire_event(Event::ActorComplete.new(response[:agent_id], response[:token], response[:status], response[:opts][:return_value]))
            end
          else
            Wakame.log.warn("#{self.class}: Unhandled agent response: #{response[:class_type]}")
          end
        }
      }

    end

    def terminate
      @agent_timeout_timer.cancel
    end

    def agent_pool
      Service::AgentPool.instance
    end

   end



   class ClusterManager
     include Manager

     class ClusterConfigLoader

       def load(cluster_rb_path=Wakame.config.cluster_config_path)
         Wakame.log.info("#{self.class}: Loading cluster.rb: #{cluster_rb_path}")
         @loaded_cluster_names = {}

         eval(File.readlines(cluster_rb_path).join(''), binding)

         # Clear uninitialized cluster data in the store.
         Service::ServiceCluster.find_all.each { |cluster|
           cluster.delete unless @loaded_cluster_names.has_key?(cluster.name)
         }

         @loaded_cluster_names
       end


       private
       def define_cluster(name, &blk)
         cluster = Service::ServiceCluster.find(Service::ServiceCluster.id(name))
         if cluster.nil?
           cluster = Service::ServiceCluster.new
           cluster.name = name
         end

         Service::AgentPool.reset
         cluster.reset

         blk.call(cluster)

         cluster.save

         Wakame.log.info("#{self.class}: Loaded Service Cluster: #{cluster.name}")
         @loaded_cluster_names[name]=cluster.id
       end

     end

     attr_reader :clusters

     def init
       @clusters = {}
       
       # Periodical cluster status updater
       @status_check_timer = EM::PeriodicTimer.new(5) {
         StatusDB.pass {
           @clusters.keys.each { |cluster_id|
             Service::ServiceCluster.find(cluster_id).update_cluster_status
           }
         }
       }
       
       # Event based cluster status updater
       @check_event_tickets = []
       [Event::ServiceOnline, Event::ServiceOffline, Event::ServiceFailed].each { |evclass|
         @check_event_tickets << EventDispatcher.subscribe(evclass) { |event|
           StatusDB.pass {
             @clusters.keys.each { |cluster_id|
               Service::ServiceCluster.find(cluster_id).update_cluster_status
             }
           }
         }
       }

     end

     def reload
     end


     def terminate
       @status_check_timer.cancel
       @check_event_tickets.each { |t|
         EventDispatcher.unsubscribe(t)
       }
     end

     def register(cluster)
       raise ArgumentError unless cluster.is_a?(Service::ServiceCluster)
       @clusters[cluster.id]=1
     end

     def unregister(cluster_id)
       @clusters.delete(cluster_id)
     end

     def load_config_cluster
       ClusterConfigLoader.new.load.each { |name, id|
         @clusters[id]=1
       }
       resolve_template_vm_attr
     end


     private
     def resolve_template_vm_attr
       @clusters.keys.each { |cluster_id|
         cluster = Service::ServiceCluster.find(cluster_id)

         if cluster.template_vm_attr.nil? || cluster.template_vm_attr.empty?
           # Set a single shot event handler to set the template values up from the first connected agent.
           EventDispatcher.subscribe_once(Event::AgentMonitored) { |event|
             StatusDB.pass {
               require 'right_aws'
               ec2 = RightAws::Ec2.new(Wakame.config.aws_access_key, Wakame.config.aws_secret_key)
               
               ref_attr = ec2.describe_instances([event.agent.vm_attr[:instance_id]])
               ref_attr = ref_attr[0]
               
               cluster = Service::ServiceCluster.find(cluster_id)
               spec = cluster.template_vm_spec
               Service::VmSpec::EC2.vm_attr_defs.each { |k, v|
                 spec.attrs[k] = ref_attr[v[:right_aws_key]]
               }
               cluster.save

               Wakame.log.debug("ServiceCluster \"#{cluster.name}\" template_vm_attr based on VM \"#{event.agent.vm_attr[:instance_id]}\" : #{spec.attrs.inspect}")
             }
           }
         end

         if cluster.advertised_amqp_servers.nil?
           StatusDB.pass {
             cluster = Service::ServiceCluster.find(cluster_id)
             cluster.advertised_amqp_servers = master.amqp_server_uri.to_s
             cluster.save
             Wakame.log.debug("ServiceCluster \"#{cluster.name}\" advertised_amqp_servers: #{cluster.advertised_amqp_servers}")
           }
         end

       }
     end

   end

   class Master
     include Wakame::AMQPClient
     include Wakame::QueueDeclare

     define_queue 'agent_event', 'agent_event'
     define_queue 'ping', 'ping'
     define_queue 'registry', 'registry'

     attr_reader :command_queue, :agent_monitor, :cluster_manager, :action_manager, :started_at
     attr_reader :managers

    def initialize(opts={})
      pre_setup
    end


    def actor_request(agent_id, path, *args)
      request = Wakame::Packets::ActorRequest.new(agent_id, Util.gen_id, path, *args)
      ActorRequest.new(self, request)
    end


    def cleanup
      @managers.each { |m| m.terminate }
      @command_queue.shutdown
    end

    def register_manager(manager)
      raise ArgumentError unless manager.kind_of? Manager
      manager.master = self
      @managers << manager
      manager
    end

    # post_setup
    def init
      raise 'has to be put in EM.run context' unless EM.reactor_running?
      @command_queue = register_manager(CommandQueue.new)

      # WorkerThread has to run earlier than other managers.
      @agent_monitor = register_manager(AgentMonitor.new)
      @cluster_manager = register_manager(ClusterManager.new)
      @action_manager = register_manager(ActionManager.new)

      @managers.each {|m|
        Wakame.log.debug("Initializing Manager Module: #{m.class}")
        m.init
      }

      Wakame.log.info("Started master process : WAKAME_ROOT=#{Wakame.config.root_path} WAKAME_ENV=#{Wakame.config.environment}")
    end


    private
    def pre_setup
      @started_at = Time.now
      @managers = []

      StatusDB::WorkerThread.init

      StatusDB.pass {
        Wakame.log.debug("Binding thread info to EventDispatcher.")
        EventDispatcher.instance.bind_thread(Thread.current)
      }
    end


  end


  class ActorRequest
    attr_reader :master, :return_value

    def initialize(master, packet)
      raise TypeError unless packet.is_a?(Wakame::Packets::ActorRequest)

      @master = master
      @packet = packet
      @requested = false
      @event_ticket = nil
      @return_value = nil
      @wait_lock = ::Queue.new
    end


    def request
      raise "The request has already been sent." if @requested

      @event_ticket = EventDispatcher.subscribe(Event::ActorComplete) { |event|
        if event.token == @packet.token
         
          # Any of status except RUNNING are accomplishment of the actor request.
          Wakame.log.debug("#{self.class}: The actor request has been completed: token=#{self.token}, status=#{event.status}, return_value=#{event.return_value}")
          EventDispatcher.unsubscribe(@event_ticket)
          @return_value = event.return_value
          @wait_lock.enq([event.status, event.return_value])
        end
      }
      Wakame.log.debug("#{self.class}: Send the actor request: #{@packet.path}@#{@packet.agent_id}, token=#{self.token}")
      master.publish_to('agent_command', "agent_id.#{@packet.agent_id}", @packet.marshal)
      @requested = true
      self
    end


    def token
      @packet.token
    end

    def progress
      check_requested?
      raise NotImplementedError
    end

    def cancel
      check_requested?
      raise NotImplementedError
      
      #master.publish_to('agent_command', "agent_id.#{@packet.agent_id}", Wakame::Packets::ActorCancel.new(@packet.agent_id, ).marshal)
      #ED.unsubscribe(@event_ticket)
    end

    def wait_completion(tout=60*30)
      check_requested?
      timeout(tout) {
        Wakame.log.debug("#{self.class}: Waiting a response from the actor: #{@packet.path}@#{@packet.agent_id}, token=#{@packet.token}")
        ret_status, ret_val = @wait_lock.deq
        Wakame.log.debug("#{self.class}: A response (status=#{ret_status}) back from the actor: #{@packet.path}@#{@packet.agent_id}, token=#{@packet.token}")
        if ret_status == Actor::STATUS_FAILED
          raise RuntimeError, "Failed status has been returned: Actor Request #{token}"
        end
        ret_val
      }
    end
    alias :wait :wait_completion
    
    private
    def check_requested?
      raise "The request has not been sent yet." unless @requested
    end
  end
end
