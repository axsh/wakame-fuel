
module EventMachine
  def self::defer op, callback = nil
    @need_threadqueue ||= 0
    if @need_threadqueue == 0
      @need_threadqueue = 1
      require 'thread'
      @threadqueue = Queue.new
      @resultqueue = Queue.new
      @thread_g = ThreadGroup.new
      20.times {|ix|
        t = Thread.new {
          my_ix = ix
          loop {
            op,cback = @threadqueue.pop
            begin
              result = op.call
              @resultqueue << [result, cback]
            rescue => e
              puts "#{e} in EM defer thread pool : #{Thread.current}"
              raise e
            ensure
              EventMachine.signal_loopbreak
            end
          }
        }
        @thread_g.add(t)
      }
    end
    
    @threadqueue << [op,callback]
  end

  # 0.12.2 is missing the stub method in pure_ruby backend.
  if EventMachine.library_type == :pure_ruby
    class Connection
      def associate_callback_target sig
        # No-op for the time being
      end
    end
  end

end
