#!/usr/bin/ruby

require 'rubygems'
require 'eventmachine'
require 'mq'
require 'thread'
require 'mutex_m'
require 'forwardable'

require 'wakame'
require 'wakame/amqp_client'
require 'wakame/packets'
require 'wakame/service'
require 'wakame/queue_declare'
require 'wakame/event'
require 'wakame/vm_manipulator'



module Wakame
  
  class ServiceMonitor
    include Wakame

    attr_reader :timers
    def initialize 
      @timers = {}
      @svcs = {}
    end
    
    def monitors(&blk)
      @svcs.each { |k,v|
        blk.call(v) if blk
      }
    end

    def [](key)
      key = key.is_a?(ServiceRunner) ? key.instance_id : key.to_s
      @svcs[key]
    end

    def is_monitored?(key)
      key = key.is_a?(ServiceRunner) ? key.instance_id : key.to_s
      @svcs.has_key?(key)
    end

    def register(runner, check_time=nil)
        raise "Duplicate service registration : #{runner.property.class}"  if is_monitored?(runner)
        node = Node.new(runner, self)

        @svcs[runner.instance_id]=node
        @timers[runner.instance_id]=CheckerTimer.new((check_time || runner.property.check_time), node)
        log.debug("#{runner.property.class.to_s} has been registered in monitor")
    end

    def unregister(instance_id)
        raise "Can not find the instance : #{instance_id}"  unless is_monitored?(instance_id)
        node = @svcs[instance_id]

        @svcs.delete(instance_id)
        t = @timers[instance_id]
        t.cancel if t
        @timers.delete(instance_id)
        log.debug("#{node.runner.property.class} has been unregistered from monitor")
    end

    def suspend_monitor
    end


    class Node
      include Wakame

      attr_reader :runner, :status_changed_at, :last_checked_at
      attr_accessor :status, :assigned_status
      
      attr_accessor :parent


      def initialize(runner, svc_mon)
        raise TypeError unless runner.is_a?(ServiceRunner)
        @runner = runner
        @assigned_status = @status = Service::STATUS_UNKNOWN
        @status_changed_at = Time.now
        @check_serial_m = Mutex.new
        @parent = svc_mon
      end

      def status_fail(message)
        status = Service::STATUS_FAIL

        event = Event::ServiceFailed.new(@runner.instance_id, @runner.property, message)
        event.time = @status_changed_at.dup
        Agent.instance.send_event_response(event)
      end

      def status=(status)
        if @status != status
          prev_status = @status
          @status = status
          @status_changed_at = Time.now
          log.debug "Service status changed : #{runner.property.class} id=#{runner.instance_id} : #{prev_status} -> #{@status}"
          
          event = Event::ServiceStatusChanged.new(@runner.instance_id, @runner.property, @status, prev_status)
          event.time = @status_changed_at.dup
          EH.fire_event(event)
        end
        self.status
      end

      def update_status(defered=true)
        pre =  proc {
          new_status = prev_status = @status
          flag=nil

          # skip to run check() when the node got failed.
          if new_status == Service::STATUS_FAIL
            Wakame.log.debug("Skip to update_status()")
            next nil
          end

          flag = begin
                   @last_checked_at = Time.now
                   @check_serial_m.synchronize { runner.check }
                 rescue => e
                   log.error(e)
                   e
                 end
          if flag.is_a? Exception
            #new_status = Service::STATUS_FAIL
            new_status = Service::STATUS_UNKNOWN
          elsif flag.is_a?(TrueClass) || flag.is_a?(FalseClass)
            new_status = flag ? Service::STATUS_ONLINE : Service::STATUS_OFFLINE
            Wakame.log.debug("#{runner.property.class}(#{runner.instance_id}) has been identified -> status=#{new_status}") if defered == false
          else
            new_status = Service::STATUS_UNKNOWN
          end
          
          Wakame.log.debug("#{runner.property.class.to_s}(#{runner.instance_id}) has been checked -> status=#{new_status}") if defered == false
            
          [prev_status, new_status, flag]
        }

        post = proc { |res|
          next if res.nil?

          prev_status = res[0]
          new_status = res[1]
          flag = res[2]
          
          self.status = new_status

#           begin
#             if prev_status != new_status
#               self.status = new_status
              
#               if prev_status != Service::STATUS_ONLINE && new_status == Service::STATUS_ONLINE
#                 EH.fire_event(Event::ServiceOnline.new(@runner.instance_id, @runner.property, @status_changed_at))
#               elsif prev_status != Service::STATUS_OFFLINE && new_status == Service::STATUS_OFFLINE
#                 EH.fire_event(Event::ServiceOffline.new(@runner.instance_id, @runner.property, @status_changed_at))
#               end
#             end
#           rescue => e
#             log.error(e)
#           end
        }

        if defered 
          EM.defer pre, post
        else
          post.call(pre.call)
        end

      end


    end
    
    class CheckerTimer < EventMachine::PeriodicTimer
      attr_reader :node

      def initialize(time, n)
        @node = n
        super(time) {
          @node.update_status
        }
      end
    end
  end


  class Ping
  end

  class ServiceRunner
    extend Forwardable
    attr_reader :instance_id, :property

    def_delegator :@property, :start
    def_delegator :@property, :stop
    def_delegator :@property, :reload
    def_delegator :@property, :check

    # instance_id is given from Master's ServiceInstance object
    def initialize(instance_id, property)
      @instance_id = instance_id
      @property = property
    end
  end

  class Agent
    include Wakame
    include Wakame::AMQPClient

    include Wakame::QueueDeclare

    define_queue 'agent_command.%{agent_id}', 'agent_command', {:key=>'agent_id.%{agent_id}', :exclusive=>true}

    def agent_id
      @agent_id ||= attr[:instance_id]
    end

    def attr
      @attr
    end

    def initialize(opts={})
      collect_system_info

      EM.barrier {
        Wakame.log.info("Binding thread info for EventHandler.")
        EventHandler.instance.bind_thread(Thread.current)
      }

      connect(opts) {

        EM.add_periodic_timer(10) { 
          send_ping
        }

        @cmd_queue = Queue.new
        @cmd_t = Thread.start {
          log.debug "Started command queue thread: #{Thread.current.inspect} waiting=#{@cmd_queue.num_waiting}"

          while ary = @cmd_queue.pop
            cmd = ary[0]

            begin
              process_command(cmd)
            rescue => e
              log.error e
              raise e
            end
          end
        }

        add_subscriber("agent_command.#{@agent_id}") {|data|
          send_cmd(Marshal.load(data))
        }
       
        [Event::ServiceStatusChanged].each { |klass|
          EventHandler.subscribe(klass) { |event|
            log.debug "#{event.class.to_s} has been received on the thread [#{Thread.current.inspect}]"

            EM.next_tick {
              send_event_response(event)
            }
          }
        }
        #EventHandler.subscribe(Event::ServiceStatusChanged) { |event|
        #  log.debug "#{event.class.to_s} has been received on the thread [#{Thread.current.inspect}]"
        #  
        #  EM.next_tick {
        #    send_event_response.call(event)
        #  }
        #}
        
        
      }
      log.debug "Agent has started on #{Thread.current.inspect}"
    end


    def send_event_response(event)
      log.debug("Sending event to master : #{event.class}")
      publish_to('agent_event', Marshal.dump(Packets::Agent::EventResponse.new(self, event)))
    end


    def cleanup
      @cmd_t.kill
    end

    def service_monitor
      @service_monitor ||= ServiceMonitor.new
    end
    alias :svc_mon :service_monitor

    def send_cmd(cmd)
      @cmd_queue.push([cmd])
    end


    def send_ping
      out = `uptime`
      if out =~ /load averages?: (.*)/
        a,b,c = $1.split(/\s+|,\s+/)
        #self.attr[:uptime] = (a.to_f + b.to_f + c.to_f) / 3
        #self.attr[:uptime] = (a.to_f + b.to_f) / 2
        self.attr[:uptime] = a.to_f
      end
      services = []
      svc_mon.monitors { |n|
        services << {:instance_id=>n.runner.instance_id, :status=>n.status}
      }
      ping = Packets::Agent::Ping.new(self, services)
      publish_to('ping', Marshal.dump(ping))
    end



    private
    def collect_system_info
      @attr = Wakame.new_( Wakame.config.vm_manipulation_class ).fetch_local_attrs
    end

    def collect_ip_info1
      # Default gw interface & its ip address

      @gw_if=nil
      @agent_ip=nil
      Wakame.shell.transact {
        system('netstat', '-nr').each { |l|
          l = l.split(/\s+/)
          if l[0].match(/^0\.0\.0\.0$/)
            @gw_if=l[7].dup
          end
        }
        break unless @gw_if
        
        system('ifconfig', @gw_if).each { |l|
          l = l.split(/\s+/)
          break unless l.size > 2
          if l[1].match(/^inet$/)

            @agent_ip = l[2].dup
            @agent_ip.sub!(/^addr:/, '')
          end
        }
      }

    end

    class RetryAgain < StandardError; end

    def process_command(command)
      log.debug("Received command #{command.class.to_s} from master node")
      retry_proc = nil

      case command
      when Packets::Agent::Nop
        #log.debug "Command Nop"
      when Packets::Agent::ServiceStart
        svc = ServiceRunner.new(command.instance_id, command.property)
        svc_mon.register(svc) unless svc_mon.is_monitored?(svc)
        
        mon = svc_mon[svc]
        mon.assigned_status = Service::STATUS_ONLINE

        retry_proc = proc {
          mon.update_status(false)
          next if mon.status == mon.assigned_status
          
          start = Time.now
          begin
            log.debug("Trying to start service #{mon.runner.property.class}")
            mon.runner.start
          end
          spent = Time.now - start
          
          # Run the check() method once within synchronized mode
          mon.update_status(false)
          #sleep 1.0 - (spent - start) if (spent - start) < 1.0
          sleep 3.0
          if mon.status == mon.assigned_status
            Wakame.log.info("#{mon.runner.property.class} (#{mon.runner.instance_id}) has successfully been ONLINE")
          else
            raise RetryAgain 
          end
        }
      when Packets::Agent::ServiceStop
        instance_id = command.instance_id
        
        mon = svc_mon[instance_id]
        mon.assigned_status = Service::STATUS_OFFLINE

        retry_proc = proc {
          mon.update_status(false)
          next if mon.status == mon.assigned_status

          start = Time.now
          begin
            log.debug("Trying to stop service #{mon.runner.property.class}")
            mon.runner.stop
          end
          spent = Time.now - start
          
          # Run the check() method once within synchronized mode
          sleep 3.0
          mon.update_status(false)
          log.debug " status=#{mon.status}"
          if mon.status == mon.assigned_status
            svc_mon.unregister(instance_id)
            Wakame.log.info("#{mon.runner.property.class} (#{mon.runner.instance_id}) has successfully been OFFLINE")
          else
            raise RetryAgain
          end
        }
      when Packets::Agent::ServiceReload
        instance_id = command.instance_id
        
        mon = svc_mon[instance_id]

        retry_proc = proc {
          if mon.status != Service::STATUS_ONLINE
            Wakame.log.info("Skip to reload the service as this is not online.")
            next
          end
          
          start = Time.now
          begin
            log.debug("Trying to reload service #{mon.runner.property.class}")
            mon.runner.reload
          end
          spent = Time.now - start
          
          # Run the check() method once within synchronized mode
          sleep 3.0
          mon.update_status(false)
          if mon.status == mon.assigned_status
            Wakame.log.info("#{mon.runner.property.class} (#{mon.runner.instance_id}) has successfully been RELOADED")
          else
            raise RetryAgain
          end
        }
        
      else
        raise "Unknown command : #{command.inspect}"
      end
      
      
      if retry_proc

        retry_cur = 0
        retry_max=5
        begin
          retry_proc.call
        rescue => e
          log.error(e) unless e.is_a?(RetryAgain)
          retry_cur += 1
          if retry_cur < retry_max
            log.error "Retrying #{retry_cur}/#{retry_max}"
            retry
          else
            mon.status_fail(e.inspect)
          end
        end

      end

      #log.debug "End process_command()"
    end
  end


end 


require 'uri'
require 'ext/uri'
require 'optparse'


module Wakame
  class AgentRunner
    include Wakame::Daemonize

    def initialize(argv)
      @argv = argv

      @options = {
        :amqp_server => URI.parse('amqp://guest@localhost/'),
        :log_file => '/var/log/wakame-agent.log',
        :pid_file => '/var/run/wakame/wakame-agent.pid',
        :daemonize => true
      }

      parser.parse! @argv
    end


    def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = "Usage: agent [options]"

        opts.separator ""
        opts.separator "Agent options:"
        opts.on( "-p", "--pid PIDFILE", "pid file path" ) {|str| @options[:pid_file] = str }
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
        Signal.trap(i) { Agent.stop{ remove_pidfile } }
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
     
      if @options[:daemonize]
        daemonize(@options[:log_file])
      end

      EM.epoll if Wakame.config.eventmachine_use_epoll
      EM.run {
        Agent.start(opts)
      }
    end

  end
end
