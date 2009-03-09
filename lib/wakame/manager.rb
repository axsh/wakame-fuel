#!/usr/bin/ruby


require 'rubygems'
require 'eventmachine'
require 'amqp'
require 'mq'
require 'thread'
require 'mutex_m'
require 'drb/drb'

require 'wakame'
require 'wakame/amqp_client'
require 'wakame/packets'
require 'wakame/service'
require 'wakame/queue_declare'
require 'wakame/event'
require 'wakame/vm_manipulator'
require 'wakame/manager/commands'
require 'wakame/configuration_template'

module Wakame
  
  class CommandQueue
    include Wakame
    
    attr_reader :master, :last_command


    def initialize(master)
      @master = master
      @queue_id = gen_id
      @cmd_queue = Queue.new

      @cmd_t = Thread.start {
        log.debug "Started command queue thread: #{Thread.current.inspect} waiting=#{@cmd_queue.num_waiting}"
        
        while cmd = @cmd_queue.pop
          @last_command = cmd = cmd[0]
          begin 
            process_command(cmd)
          rescue => e
            log.error(e)
            raise e
          end
        end
      }
      @cmd_t[:name]="#{self.class} command queue"

      DRb.start_service(Wakame.config.drb_command_server_uri, Manager::CommandDelegator.new(self))
    end

    def send_cmd(cmd)
      @cmd_queue.push([cmd])
    end

    private
    def process_command(command)
      log.debug "Start process_command(#{command.inspect}) on #{Thread.current.inspect}"

      EH.fire_event(Event::CommandReceived.new(command))
    end
    
  end




  class InstanceMonitor
    def initialize(master)
      @master = master
      
    end
  end


  class AgentMonitor
    include Wakame

    class Agent
      STATUS_DOWN=0
      STATUS_UP=1
      STATUS_UNKNOWN=2
      STATUS_TIMEOUT=3

      MASTER_LOCAL_AGENT_ID='__local__'

      attr_accessor :agent_id, :status, :uptime, :last_ping_at, :attr, :services

      def initialize
        extend(Sync_m)
        @services = {}
      end

      def agent_ip
        attr[:local_ipv4]
      end

      def [](key)
        attr[key]
      end

      def status=(status)
        if @status != status
          @status = status
          EH.fire_event(Event::AgentStatusChanged.new(self))
          # Send status specific event
          case status
          when STATUS_TIMEOUT
            EH.fire_event(Event::AgentTimedOut.new(self))
          end
        end
        @status
      end
      
      def has_service_type?(key)
        svc_class = case key
                    when Service::ServiceInstance
                      key.property.class
                    when Class
                      key
                    else
                      nil
                    end

        services.any? { |k, v|
          v.property.class == svc_class
        }
      end


      def dump_status
        {:agent_id => @agent_id, :status => @status, :last_ping_at => @last_ping_at, :attr => attr.dup,
          :services => services.collect{|id, svc| svc.dump_status }
        }
      end
      
    end


    attr_reader :agents, :master, :gc_period
    def initialize(master)
      extend(Sync_m)
      @master = master
      @agents = {}
      @agents.extend(Sync_m)
      @services = {}
      @agent_timeout = 31.to_f
      @agent_kill_timeout = @agent_timeout * 2
      @gc_period = 20.to_f

      # GC event trigger for agent timer & status
      agent_timeout = proc {
        #log.debug("Started agent GC : agents.size=#{@agents.size}, mutex locked=#{@agents.locked?.to_s}")
        @agents.synchronize {
          #base_time = Time.now
          kill_list=[]
          @agents.each { |agent_id, agent|
            next if agent.status == AgentMonitor::Agent::STATUS_DOWN
            #diff_time = base_time - agent.last_ping_at
            diff_time = Time.now - agent.last_ping_at
            #log.debug "AgentMonitor GC : #{agent_id}: #{diff_time}"
            if diff_time > @agent_timeout.to_f
              agent.status = AgentMonitor::Agent::STATUS_TIMEOUT
            end

            if diff_time > @agent_kill_timeout.to_f
              kill_list << agent_id
            end
          }

          kill_list.each { |agent_id|
              agent = @agents.delete(agent_id)
              EH.fire_event(Event::AgentUnMonitored.new(agent)) unless agent.nil?
          }
          #log.debug("Finished agent GC")
        }
      }
      @agent_timeout_timer = EventMachine::PeriodicTimer.new(@gc_period, proc {
                                                               EM.defer agent_timeout
                                                             })

      
      master.add_subscriber('ping') { |data|
        ping = Marshal.load(data)

        # Common member variables to be updated
        set_report_values = proc { |agent|
          agent.status = AgentMonitor::Agent::STATUS_UP
          agent.uptime = 0
          agent.last_ping_at = Time.new

          agent.attr = ping.attr

          agent.services.clear
          ping.services.each { |i|
            agent.services[i[:instance_id]] = Service::ServiceInstance.instance_collection[i[:instance_id]] || next
          }
        }

        @agents.synchronize {
          agent = @agents[ping.agent_id]
          if agent.nil?
            agent = Agent.new
            agent.agent_id = ping.agent_id

            set_report_values.call(agent)

            @agents[ping.agent_id]=agent
            EH.fire_event(Event::AgentMonitored.new(agent))
          else
            set_report_values.call(agent)
          end


          EH.fire_event(Event::AgentPong.new(agent))
        }
      }

      master.add_subscriber('agent_event') { |data|
        event_response = Marshal.load(data) # Packet::EventResponse
        event = event_response.event
        case event
        when Event::ServiceStatusChanged
          svc_inst = Service::ServiceInstance.instance_collection[event.instance_id]
          if svc_inst
            svc_inst.set_status(event.status, event.time)

            tmp_event = Event::ServiceStatusChanged.new(event.instance_id, svc_inst.property, event.status, event.previous_status)
            tmp_event.time = event.time
            EH.fire_event(tmp_event)

            if event.previous_status != Service::STATUS_ONLINE && event.status == Service::STATUS_ONLINE
              tmp_event = Event::ServiceOnline.new(event.instance_id, svc_inst.property)
              tmp_event.time = event.time
              EH.fire_event(tmp_event)
            elsif event.previous_status != Service::STATUS_OFFLINE && event.status == Service::STATUS_OFFLINE
              tmp_event = Event::ServiceOffline.new(event.instance_id, svc_inst.property)
              tmp_event.time = event.time
              EH.fire_event(tmp_event)
            end
          end
        else
          EH.fire_event(event)
        end
      }

      #EH.subscribe(Event::AgentPong) { |event|
      #  event.agent.services.each { |svc_id, svc|
      #    svc = Service::ServiceInstance.instance_collection[svc_id] || next
      #    svc.bind_agent(event.agent)
      #  }
      #}

    end


    def bind_agent(service_instance, &filter)
      agent_id, agent = @agents.find { |agent_id, agent|

        next false if agent.has_service_type?(service_instance.property.class)
        filter.call(agent)
      }
      return nil if agent.nil?
      service_instance.bind_agent(agent)
      agent
    end

    def unbind_agent(service_instance)
      service_instance.unbind_agent
    end


    def dump_status
      ag = []
      agents.each { |key, a|
        ag << a.dump_status
      }

      {:agents => ag}
    end
  end

  class Master
    include Wakame
    include Wakame::AMQPClient

    include Wakame::QueueDeclare

    define_queue 'agent_event', 'agent_event'
    define_queue 'ping', 'ping'

    attr_reader :command_queue, :agent_monitor, :configuration, :service_cluster, :attr

    def initialize(opts={})
      super()
      pre_setup

      connect(opts) {
        post_setup
      }
      Wakame.log.info("Started master process : WAKAME_ROOT=#{Wakame.config.root} ")
    end


    def send_agent_command(command, agent_id=nil)
      raise TypeError unless command.is_a? Packets::Agent::RequestBase
      EM.next_tick {
        if agent_id
          publish_to('agent_command', "agent_id.#{agent_id}", Marshal.dump(command))
        else
          publish_to('agent_command', '*', Marshal.dump(command))
        end
      }
    end


    private
    def collect_system_info
      @attr = Wakame.new_( Wakame.config.vm_manipulation_class ).fetch_local_attrs
    end

    def pre_setup
      collect_system_info
      

    end

    def post_setup
      raise 'has to be put in EM.run context' unless EM.reactor_running?
      @command_queue = CommandQueue.new(self)
      @agent_monitor = AgentMonitor.new(self)

      @service_cluster = Service::WebCluster.new(self)
      # @service_cluster.rule_engine = Manager::RuleEngine.new(self, cluster) {
      # }


    end

  end
end


require 'uri'
require 'ext/uri'
require 'optparse'

module Wakame
  class MasterRunner
    include Wakame::Daemonize

    def initialize(argv)
      @argv = argv

      @options = {
        :amqp_server => URI.parse('amqp://guest@localhost/'),
        :log_file => '/var/log/wakame-master.log',
        :pid_file => '/var/run/wakame-master.pid',
        :daemonize => true
      }

      parser.parse! @argv
    end


    def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = "Usage: master [options]"

        opts.separator ""
        opts.separator "Master options:"
        opts.on( "-p", "--pid PIDFILE", "pid file path" ) {|str| @options[:pid_file] = str }
        opts.on( "-u", "--u UID", "user id for the running process" ) {|str| @options[:uid] = str }
        opts.on( "-s", "--server AMQP_URI", "amqp server" ) {|str|
          begin 
            @options[:amqp_server] = URI.parse(str)
          rescue URI::InvalidURIError => e
            fail "#{e}"
          end
        }
        opts.on("-X", "", "daemonize flag" ) { @options[:daemonize] = false }
        
      end


    end

    
    def run
      %w(QUIT INT TERM).each { |i|
        Signal.trap(i) { Master.stop{ remove_pidfile } }
      }

      unless @options[:amqp_server].nil?
        uri = @options[:amqp_server]
        default = AMQP.settings
        opts = {:host => uri.host,
          :port => uri.port || default[:port],
          :vhost => uri.vhost || default[:vhost],
          :user=>uri.user || default[:user],
          :pass=>uri.password ||default[:pass]
        }
      else
        opts = nil
      end
     
      setup_pidfile

      if @options[:daemonize]
        daemonize(@options[:log_file])
      end

      change_privilege(@options[:uid]) if @options[:uid]

      EM.epoll if Wakame.config.eventmachine_use_epoll
      EM.run {
        Master.start(opts)

EM.add_periodic_timer(5) {
next
          buf = ''
          buf << "<--- RUNNING THREADS --->\n"
          ThreadGroup::Default.list.each { |i|
            buf << "#{i.inspect} #{i[:name].to_s}\n"
          }
          buf << ">--- RUNNING THREADS ---<\n"
          puts buf
}
      }
    end

  end
end
