
module Wakame
  module Triggers
    class ProcessCommand < Trigger
      def register_hooks
        @@command_thread ||= Thread.new {
          while cmd = self.command_queue.deq_cmd
            res = nil
            begin
              EM.barrier {
                Wakame.log.debug("#{self.class}: Being processed the command: #{cmd.class}")
                cmd.run(self)
                res = cmd
              }
            rescue => e
              Wakame.log.error(e)
              res = e
            ensure
              self.command_queue.enq_result(res)
            end
          end
        }
        
        #event_subscribe(Event::CommandReceived) { |event|
        #  event.command.run(self)
        #}
      end
      
      def cleanup
        @@command_thread.kill if @@command_thread.alive?
      end
    end
  end
end
