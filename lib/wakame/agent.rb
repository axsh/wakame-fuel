#!/usr/bin/ruby

require 'rubygems'

require 'eventmachine'
require 'mq'
require 'thread'

require 'wakame'
require 'wakame/amqp_client'
require 'wakame/queue_declare'
require 'wakame/event'
require 'wakame/vm_manipulator'


module Wakame
  class Agent
    include AMQPClient
    include QueueDeclare

    #define_queue 'agent_command.%{agent_id}', 'agent_command', {:key=>'agent_id.%{agent_id}', :auto_delete=>true}
    define_queue 'agent_actor.%{agent_id}', 'agent_command', {:key=>'agent_id.%{agent_id}', :auto_delete=>true}

    attr_reader :actor_registry, :monitor_registry

    def agent_id
      @agent_id
    end

    def initialize(opts={})
      determine_agent_id
      @actor_registry = ActorRegistry.new
      @monitor_registry = MonitorRegistry.new

      connect(opts)

      setup_monitors
      setup_actors
      setup_dispatcher

      publish_to('registry', Packets::Agent::Register.new(self).marshal)
      Wakame.log.info "Started Agent"
    end


    def send_event_response(event)
      Wakame.log.debug("Sending event to master : #{event.class}")
      publish_to('agent_event', Marshal.dump(Packets::Agent::EventResponse.new(self, event)))
    end

    def cleanup
      publish_to('registry', Packets::Agent::UnRegister.new(self).marshal)
      #@cmd_t.kill
    end

    attr_reader :monitors, :actors

    def determine_agent_id
      if Wakame.config.environment == :EC2
        @agent_id = VmManipulator::EC2::MetadataService.query_metadata_uri('instance-id')
      else
        @agent_id = '__standalone__'
      end
    end


    def setup_monitors
      load_monitors

      @monitor_registry.register(Monitor::Agent.new, '/agent')
      @monitor_registry.register(Monitor::Service.new, '/service')
      
      @monitor_registry.monitors.each { |path, mon|
        mon.setup(path)
        mon.agent = self
      }
    end

    def load_monitors
      require 'wakame/monitor/agent'
      require 'wakame/monitor/service'
    end

    def setup_actors
      load_actors

      @actor_registry.register(Actor::ServiceMonitor.new, '/service_monitor')
      @actor_registry.actors.each { |path, actor|
#        actor.setup(path)
        actor.agent = self
      }
    end
    
    def load_actors
      require 'wakame/actor/service_monitor'
    end


    def setup_dispatcher
      @dispatcher = Dispatcher.new(self)
      
      add_subscriber("agent_actor.#{agent_id}") { |data|
        data = eval(data)
        @dispatcher.handle_request(data)
      }
    end

  end


  class ActorRegistry
    attr_reader :actors
    def initialize()
      @actors = {}
    end

    def register(actor, path=nil)
      raise '' unless actor.kind_of?(Wakame::Actor)

      if path.nil?
        path = '/' + Util.to_const_path(actor.class.to_s)
      end

      if @actors.has_key?(path)
        Wakame.log.error("#{self.class}: Duplicate registration: #{path}")
        raise "Duplicate registration: #{path}"
      end
      
      @actors[path] = actor
    end

    def unregister(path)
      @actors.delete(path)
    end

    def find_actor(path)
      @actors[path]
    end

  end


  class MonitorRegistry
    attr_reader :monitors
    def initialize()
      @monitors = {}
    end

    def register(monitor, path=nil)
      raise '' unless monitor.kind_of?(Wakame::Monitor)

      if path.nil?
        path = '/' + Util.to_const_path(monitor.class.to_s)
      end

      if @monitors.has_key?(path)
        Wakame.log.error("#{self.class}: Duplicate registration: #{path}")
        raise "Duplicate registration: #{path}"
      end
      
      @monitors[path] = monitor
    end

    def unregister(path)
      @monitors.delete(path)
    end

    def find_monitor(path)
      @monitors[path]
    end
  end


  class Dispatcher
    attr_reader :agent

    def initialize(agent)
      @agent = agent
    end

    def handle_request(request)
      slash = request[:path].rindex('/')
      raise "Invalid request path: #{request[:path]}" unless slash

      prefix = request[:path][0, slash]
      action = request[:path][slash+1, request[:path].length]

      actor = agent.actor_registry.find_actor(prefix)
      unless actor
        Wakame.log.error("No refered actor instance: #{prefix}")
        raise
      end

      EM.defer(proc {
                 begin
                   actor.send(action, *request[:args])
                 rescue => e
                   #Wakame.log.error("#{self.class}: #{request[:id]}")
                   Wakame.log.error(e)
                 end
               }, proc { |res|
                 #agent.publish_to('agent_event', )
               })

    end
  end
  

end 
