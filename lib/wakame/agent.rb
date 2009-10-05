#!/usr/bin/ruby

require 'rubygems'

require 'eventmachine'
require 'mq'
require 'thread'

require 'wakame'
require 'wakame/amqp_client'
require 'wakame/queue_declare'
#require 'wakame/event'
#require 'wakame/vm_manipulator'


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
    end

    # post_setup
    def init
      setup_monitors
      setup_actors
      setup_dispatcher

      if Wakame.config.environment == :EC2
        attrs = self.class.ec2_fetch_local_attrs
      else
        attrs = {}
      end
      publish_to('registry', Packets::Register.new(self, Wakame.config.root_path.to_s, attrs).marshal)
      Wakame.log.info("Started agent process : WAKAME_ROOT=#{Wakame.config.root_path} WAKAME_ENV=#{Wakame.config.environment}, attrs=#{attrs.inspect}")
    end

#     def send_event_response(event)
#       Wakame.log.debug("Sending event to master : #{event.class}")
#       publish_to('agent_event', Marshal.dump(Packets::EventResponse.new(self, event)))
#     end

    def cleanup
      publish_to('registry', Packets::UnRegister.new(self).marshal)
      #@cmd_t.kill
    end

    def determine_agent_id
      if Wakame.config.environment == :EC2
        @agent_id = self.class.ec2_query_metadata_uri('instance-id')
      else
        @agent_id = '__STAND_ALONE__'
      end
    end


    def setup_monitors
      @monitor_registry.register(Monitor::Agent.new, '/agent')
      @monitor_registry.register(Monitor::Service.new, '/service')
      
      @monitor_registry.monitors.each { |path, mon|
        mon.agent = self
        mon.setup(path)
      }
    end

    def setup_actors
      @actor_registry.register(Actor::ServiceMonitor.new, '/service_monitor')
      @actor_registry.register(Actor::Daemon.new, '/daemon')
      @actor_registry.register(Actor::System.new, '/system')
      @actor_registry.register(Actor::MySQL.new, '/mysql')
      @actor_registry.register(Actor::Deploy.new, '/deploy')
      @actor_registry.actors.each { |path, actor|
#        actor.setup(path)
        actor.agent = self
      }
    end
    
    def setup_dispatcher
      @dispatcher = Dispatcher.new(self)
      
      add_subscriber("agent_actor.#{agent_id}") { |data|
        begin
          request = eval(data)
          @dispatcher.handle_request(request)
        rescue => e
          Wakame.log.error(e)
          publish_to('agent_event', Packets::ActorResponse.new(self, request[:token], Actor::STATUS_FAILED, {:message=>e.message, :exclass=>e.class.to_s}).marshal)
        end
      }
    end

    def self.ec2_query_metadata_uri(key)
      require 'open-uri'
      open("http://169.254.169.254/2008-02-01/meta-data/#{key}") { |f|
        return f.readline
      }
    end

    def self.ec2_fetch_local_attrs
      attrs = {}
      %w[instance-id instance-type local-ipv4 local-hostname public-hostname public-ipv4 ami-id].each { |key|
        rkey = key.tr('-', '_')
        attrs[rkey.to_sym]=ec2_query_metadata_uri(key)
      }
      attrs[:availability_zone] = ec2_query_metadata_uri('placement/availability-zone')
      attrs
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
      slash = request[:path].rindex('/') || raise("Invalid request path: #{request[:path]}")

      prefix = request[:path][0, slash]
      action = request[:path][slash+1, request[:path].length]

      actor = agent.actor_registry.find_actor(prefix) || raise("Invalid request path: #{request[:path]}")

      EM.defer(proc {
                 begin
                   Wakame.log.debug("#{self.class}: Started to run the actor: #{actor.class}, token=#{request[:token]}")
                   agent.publish_to('agent_event', Packets::ActorResponse.new(agent, request[:token], Actor::STATUS_RUNNING).marshal)
                   if request[:args].nil?
                     actor.send(action)
                   else
                     actor.send(action, *request[:args])
                   end
                   Wakame.log.debug("#{self.class}: Finished to run the actor: #{actor.class}, token=#{request[:token]}")
                   actor.return_value
                 rescue => e
                   Wakame.log.error("#{self.class}: Failed the actor: #{actor.class}, token=#{request[:token]}")
                   Wakame.log.error(e)
                   e
                 end
               }, proc { |res|
                 status = Actor::STATUS_SUCCESS
                 if res.is_a?(Exception)
                   status = Actor::STATUS_FAILED
                   opts = {:message => res.message, :exclass=>res.class.to_s}
                 else
                   opts = {:return_value=>res}
                 end
                 agent.publish_to('agent_event', Packets::ActorResponse.new(self.agent, request[:token], status, opts).marshal)
               })
    end
  end
  

end 
