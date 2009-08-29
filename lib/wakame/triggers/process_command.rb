
module Wakame
  module Triggers
    class ProcessCommand < Trigger

      def register_hooks
        @command_thread ||= Thread.new {
          Wakame.log.info("#{self.class}: Started process command thread.")
          while cmd = self.command_queue.deq_cmd
            unless cmd.kind_of?(Wakame::Command)
              Wakame.log.warn("#{self.class}: Incompatible type of object has been sent to ProcessCommand thread. #{cmd.class}")
              next
            end

            res = nil
            begin
              StatusDB.barrier {
                Wakame.log.debug("#{self.class}: Being processed the command: #{cmd.class}")
                res = cmd.run(self)
                res
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
        @command_thread.kill if @command_thread && @command_thread.alive?
      end
    end
  end
end
