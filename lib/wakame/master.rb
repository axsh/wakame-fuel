#!/usr/bin/ruby

require 'rubygems'

require 'wakame'
require 'wakame/packets'
require 'wakame/service'
require 'wakame/queue_declare'
require 'wakame/vm_manipulator'

module Wakame

  class AgentMonitor
    include ThreadImmutable
    attr_reader :registered_agents, :unregistered_agents, :master, :gc_period


    def initialize(master)
      bind_thread
      @master = master
      @registered_agents = {}
      @unregistered_agents = {}
      @agent_timeout = 31.to_f
      @agent_kill_timeout = @agent_timeout * 2
      @gc_period = 20.to_f

      # GC event trigger for agent timer & status
      calc_agent_timeout = proc {
        #Wakame.log.debug("Started agent GC : agents.size=#{@registered_agents.size}")
        kill_list=[]
        registered_agents.each { |agent_id, agent|
          next if agent.status == Service::Agent::STATUS_OFFLINE
          diff_time = Time.now - agent.last_ping_at
          #Wakame.log.debug "AgentMonitor GC : #{agent_id}: #{diff_time}"
          if diff_time > @agent_timeout.to_f
            agent.status = Service::Agent::STATUS_TIMEOUT
          end
          
          if diff_time > @agent_kill_timeout.to_f
            kill_list << agent_id
          end
        }
        
        kill_list.each { |agent_id|
          agent = @agents.delete(agent_id)
          ED.fire_event(Event::AgentUnMonitored.new(agent)) unless agent.nil?
        }
        #Wakame.log.debug("Finished agent GC")
      }
      
      @agent_timeout_timer = EventMachine::PeriodicTimer.new(@gc_period, calc_agent_timeout)
      
      master.add_subscriber('registry') { |data|
        data = eval(data)

        agent_id = data[:agent_id]
        case data[:type]
        when 'Wakame::Packets::Register'
          register_agent(data)
        when 'Wakame::Packets::UnRegister'
          unregister_agent(agent_id)
        end
      }

      master.add_subscriber('ping') { |data|
        ping = eval(data)
        # Skip the old ping responses before starting master node.
        next if Time.parse(ping[:responded_at]) < master.started_at

        # Variable update function for the common members
        set_report_values = proc { |agent|
          agent.status = Service::Agent::STATUS_ONLINE
          agent.uptime = 0
          agent.last_ping_at = Time.parse(ping[:responded_at])
          
          agent.attr = ping[:attrs]
          
          agent.services.clear
          ping.services.each { |svc_id, i|
            agent.services[svc_id] = master.service_cluster.instances[svc_id]
          }
        }
        
        agent = agent(ping[:agent_id])
        if agent.nil?
          agent = Service::Agent.new(ping[:agent_id])
          
          set_report_values.call(agent)
          
          unregistered_agents[ping[:agent_id]]=agent
        else
          set_report_values.call(agent)
        end
        
        
        ED.fire_event(Event::AgentPong.new(agent))
      }
      
      master.add_subscriber('agent_event') { |data|
        response = eval(data)
#p response
        case response[:type]
        when 'Wakame::Packets::ServiceStatusChanged'
          svc_inst = Service::ServiceInstance.instance_collection[response[:svc_id]]
          if svc_inst
            response_time = Time.parse(response[:responded_at])
            svc_inst.update_status(response[:new_status], response_time, response[:fail_message])
            
#             tmp_event = Event::ServiceStatusChanged.new(response[:svc_id], svc_inst.property, response[:status], response[:previous_status])
#             tmp_event.time = response_time
#             ED.fire_event(tmp_event)
            
#             if response[:previous_status] != Service::STATUS_ONLINE && response[:new_status] == Service::STATUS_ONLINE
#               tmp_event = Event::ServiceOnline.new(tmp_event.instance_id, svc_inst.property)
#               tmp_event.time = response_time
#               ED.fire_event(tmp_event)
#             elsif response[:previous_status] != Service::STATUS_OFFLINE && response[:new_status] == Service::STATUS_OFFLINE
#               tmp_event = Event::ServiceOffline.new(tmp_event.instance_id, svc_inst.property)
#               tmp_event.time = response_time
#               ED.fire_event(tmp_event)
#             elsif response[:previous_status] != Service::STATUS_FAIL && response[:new_status] == Service::STATUS_FAIL
#               tmp_event = Event::ServiceFailed.new(tmp_event.instance_id, svc_inst.property, response[:fail_message])
#               tmp_event.time = response_time
#               ED.fire_event(tmp_event)
#             end
          end
        when 'Wakame::Packets::ActorResponse'
          case response[:status]
          when Actor::STATUS_RUNNING
              ED.fire_event(Event::ActorProgress.new(response[:agent_id], response[:token], 0))
          else
              ED.fire_event(Event::ActorComplete.new(response[:agent_id], response[:token], response[:status]))
          end
        else
          Wakame.log.warn("#{self.class}: Unhandled agent response: #{response[:type]}")
        end
      }
    
    end


    def agent(agent_id)
      registered_agents[agent_id] || unregistered_agents[agent_id]
    end

    def register_agent(data)
      agent_id = data[:agent_id]
      agent = registered_agents[agent_id]
      if agent.nil?
        agent = unregistered_agents[agent_id]
        if agent.nil?
          # The agent is going to be registered at first time.
          agent = Service::Agent.new(agent_id)
          registered_agents[agent_id] = agent
        else
          # Move the reference from unregistered group to the registered group.
          registered_agents[agent_id] = unregistered_agents[agent_id]
          unregistered_agents.delete(agent_id)
        end
        Wakame.log.debug("The Agent has been registered: #{data.inspect}")
        #Wakame.log.debug(unregistered_agents)
        ED.fire_event(Event::AgentMonitored.new(agent))
      end
      agent.root_path = data[:root_path]
      agent.attr = data[:attrs]
    end

    def unregister_agent(agent_id)
      agent = registered_agents[agent_id]
      if agent
        unregistered_agents[agent_id] = registered_agents[agent_id]
        registered_agents.delete(agent_id)
        ED.fire_event(Event::AgentUnMonitored.new(agent))
      end
    end


#     def bind_agent(service_instance, &filter)
#       agent_id, agent = @agents.find { |agent_id, agent|

#         next false if agent.has_service_type?(service_instance.property.class)
#         filter.call(agent)
#       }
#       return nil if agent.nil?
#       service_instance.bind_agent(agent)
#       agent
#     end

#     def unbind_agent(service_instance)
#       service_instance.unbind_agent
#     end
    
    # Retruns the master local agent object
    def master_local
      agent = registered_agents[@master.master_local_agent_id]
      puts "#{agent} = registered_agents[#{@master.master_local_agent_id}]"
      raise "Master does not identify the master local agent yet." if agent.nil?
      agent
    end

    def each_online(&blk)
      registered_agents.each { |k, v|
        next if v.status != Service::Agent::STATUS_ONLINE
        blk.call(v)
      }
    end

     def dump_status
       ag = []
       res = {:registered=>[], :unregistered=>[]}
       
       @registered_agents.each { |key, a|
         res[:registered] << a.dump_status
       }
       @unregistered_agents.each { |key, a|
         res[:unregistered] << a.dump_status
       }
       res
     end
  end

  class Master
    include Wakame::AMQPClient
    include Wakame::QueueDeclare

    define_queue 'agent_event', 'agent_event'
    define_queue 'ping', 'ping'
    define_queue 'registry', 'registry'

    attr_reader :command_queue, :agent_monitor, :configuration, :service_cluster, :started_at

    def initialize(opts={})
      pre_setup

      connect(opts) {
        post_setup
      }
      Wakame.log.info("Started master process : WAKAME_ROOT=#{Wakame.config.root_path} WAKAME_ENV=#{Wakame.config.environment}")
    end


#     def send_agent_command(command, agent_id=nil)
#       raise TypeError unless command.is_a? Packets::RequestBase
#       EM.next_tick {
#         if agent_id
#           publish_to('agent_command', "agent_id.#{agent_id}", Marshal.dump(command))
#         else
#           publish_to('agent_command', '*', Marshal.dump(command))
#         end
#       }
#     end

    def actor_request(agent_id, path, *args)
      request = Wakame::Packets::ActorRequest.new(agent_id, Util.gen_id, path, *args)
      ActorRequest.new(self, request)
    end


    def attr
      agent_monitor.master_local.attr
    end


    def cleanup
      @command_queue.shutdown
    end

    def master_local_agent_id
      @master_local_agent_id
    end

    private
    def determine_agent_id
      if Wakame.config.environment == :EC2
        @master_local_agent_id = VmManipulator::EC2::MetadataService.query_metadata_uri('instance-id')
      else
        @master_local_agent_id = VmManipulator::StandAlone::INSTANCE_ID
      end
    end

    def pre_setup
      determine_agent_id
      @started_at = Time.now

      EM.barrier {
        Wakame.log.debug("Binding thread info to EventDispatcher.")
        EventDispatcher.instance.bind_thread(Thread.current)
      }
    end

    def post_setup
      raise 'has to be put in EM.run context' unless EM.reactor_running?
      @command_queue = CommandQueue.new(self)
      @agent_monitor = AgentMonitor.new(self)

      @service_cluster = Util.new_(Wakame.config.cluster_class, self)
    end

  end


  class ActorRequest
    attr_reader :master

    def initialize(master, packet)
      raise TypeError unless packet.is_a?(Wakame::Packets::ActorRequest)

      @master = master
      @packet = packet
      @requested = false
      @event_ticket = nil
      @wait_lock = ::Queue.new
    end


    def request
      raise "The request has already been sent." if @requested

      @event_ticket = ED.subscribe(Event::ActorComplete) { |event|
       if event.token == @packet.token
         
         # Any of status except RUNNING are accomplishment of the actor request.
         Wakame.log.debug("#{self.class}: The actor request has been completed: token=#{self.token}, status=#{event.status}")
         ED.unsubscribe(@event_ticket)
         @wait_lock.enq(event.status)
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
        ret_status = @wait_lock.deq
        Wakame.log.debug("#{self.class}: A response (status=#{ret_status}) back from the actor: #{@packet.path}@#{@packet.agent_id}, token=#{@packet.token}")
        if ret_status == Actor::STATUS_FAILED
          raise RuntimeError, "Failed status has been returned: Actor Request #{token}"
        end
      }
    end
    alias :wait :wait_completion

    private
    def check_requested?
      raise "The request has not been sent yet." unless @requested
    end
  end
end
