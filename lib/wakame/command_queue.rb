
require 'drb/drb'
require 'thread'

module Wakame
  class CommandQueue
    attr_reader :master

    def initialize(master)
      @master = master
      @queue = Queue.new
      @result_queue = Queue.new

      DRb.start_service(Wakame.config.drb_command_server_uri, self)
      #@drb_server = DRb.start_drbserver(Wakame.config.drb_command_server_uri, self)
    end

    def shutdown
      DRb.stop_service()
      #@drb_server.stop_service()
    end

    def deq_cmd()
      @queue.deq
    end

    def enq_result(res)
      @result_queue.enq(res)
    end

    def send_cmd(cmd)
      begin
        #cmd = Marshal.load(cmd)
        @queue.enq(cmd)
        ED.fire_event(Event::CommandReceived.new(cmd))
        return @result_queue.deq()
      rescue => e
        Wakame.log.error("#{self.class}:")
        Wakame.log.error(e)
      end
    end

  end
end
