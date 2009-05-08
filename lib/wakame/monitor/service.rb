
require 'open4'
require 'wakame'

class Wakame::Monitor::Service

  class ServiceChecker
    include Wakame::Packets::Agent
    attr_reader :timer, :svc_id
    attr_accessor :last_checked_at, :status

    def initialize(svc_id, svc_mon)
      @svc_id = svc_id
      @service_monitor = svc_mon
      @status = Wakame::Monitor::STATUS_OFFLINE
      count = 0
      @timer = Wakame::Monitor::CheckerTimer.new(3) {
        self.signal_checker
      }
    end

    def start
      if !@timer.running?
        @timer.start
        @service_monitor.send_event(MonitoringStarted.new(@service_monitor.agent, self.svc_id))
      end
    end

    def stop
      if @timer.running?
        @timer.stop
        @service_monitor.send_event(MonitoringStopped.new(@service_monitor.agent, self.svc_id))
      end
    end

    def check
    end

    protected
    def signal_checker
      EventMachine.defer proc {
        res = begin
                self.last_checked_at = Time.now
                self.check
              rescue => e
                Wakame.log.error("#{self.class}: #{e}")
                Wakame.log.error(e)
                e
              end
                Thread.pass
        res
      }, proc { |res|

        case res
        when Exception
          update_status(Wakame::Monitor::STATUS_FAIL) 
        when Wakame::Monitor::STATUS_ONLINE, Wakame::Monitor::STATUS_OFFLINE
          update_status(res) 
        else
          Wakame.log.error("#{self.class}: Unknown response type from the checker: #{self.svc_id}, ")
        end
      }
    end

    def update_status(new_status)
      prev_status = self.status
      if prev_status != new_status
        self.status = new_status
        @service_monitor.send_event(ServiceStatusChanged.new(@service_monitor.agent, self.svc_id, prev_status, new_status))
      end
    end
  end

  class PidFileChecker < ServiceChecker
    def initialize(svc_id, svc_mon, pidpath)
      super(svc_id, svc_mon)
      @pidpath = pidpath
    end
    
    def check
      
    end
  end

  class CommandChecker < ServiceChecker
    attr_reader :command

    def initialize(svc_id, svc_mon, cmdstr)
      super(svc_id, svc_mon)
      @command = cmdstr
    end

    def check()
      outputs =[]
      cmdstat = ::Open4.popen4(@command) { |pid, stdin, stdout, stderr|
        stdout.each { |l|
          outputs << l
        }
        stderr.each { |l|
          outputs << l
        }
      }
      Wakame.log.debug("#{self.class}: Exit Status #{@command}: #{cmdstat}")
      if outputs.size > 0
        @service_monitor.send_event(MonitoringOutput.new(@service_monitor.agent, self.svc_id, outputs.join('')))
      end
      cmdstat.exitstatus == 0 ? Wakame::Monitor::STATUS_ONLINE : Wakame::Monitor::STATUS_OFFLINE
    end
  end

  include Wakame::Monitor

  attr_reader :checkers

  def initialize
    @status = STATUS_ONLINE
    @checkers = {}
  end

  def setup(path)
  end

  def handle_request(request)
    svc_id = request[:svc_id]
    case request[:command]
    when :start
      register(svc_id, request[:cmdstr])
    when :stop
      unregister(svc_id)
    end
  end

  def send_event(a)
    publish_to('agent_event', a.marshal)
  end

  def dump_attrs
  end

  def find_checker(svc_id)
    @checkers[svc_id]
  end

  def register(svc_id, cmdstr)
    chk = @checkers[svc_id]
    if chk
      Wakame.log.error("#{self.class}: Service registory duplication. #{svc_id}")
      return
    end
    chk = CommandChecker.new(svc_id, self, cmdstr)
    chk.start
    @checkers[svc_id]=chk
    Wakame.log.info("#{self.class}: Registered service checker for #{svc_id}")
  end

  def unregister(svc_id)
    chk = @checkers[svc_id]
    if chk
      chk.timer.stop
      @checkers.delete(svc_id)
      Wakame.log.info("#{self.class}: Unregistered service checker for #{svc_id}")
    end
  end

end
