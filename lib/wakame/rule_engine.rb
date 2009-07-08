
require 'timeout'

module Wakame
  class CancelActionError < StandardError; end
  class CancelBroadcast < StandardError; end
  class GlobalLockError < StandardError; end

  class RuleEngine
    
    FORWARD_ATTRS=[:command_queue, :agent_monitor, :service_cluster, :master]

    attr_reader :triggers, :active_jobs

    def master
      service_cluster.master
    end

    def command_queue
      master.command_queue
    end

    def agent_monitor
      master.agent_monitor
    end

    def service_cluster
      @service_cluster
    end

    def initialize(service_cluster, &blk)
      @service_cluster = service_cluster
      @triggers = []
      
      @active_jobs = {}
      @job_history = []
      instance_eval(&blk) if blk
    end

    def register_trigger(trigger)
      Wakame.log.debug("Registering trigger #{trigger.class}")
      trigger.bind_engine(self)
      trigger.register_hooks
      @triggers << trigger
    end

    def create_job_context(trigger, root_action)
      root_action.job_id = job_id = Wakame.gen_id

      @active_jobs[job_id] = {
        :job_id=>job_id,
        :src_trigger=>trigger,
        :create_at=>Time.now,
        :start_at=>nil,
        :complete_at=>nil,
        :root_action=>root_action,
        :notes=>{}
      }
    end

    def cancel_action(job_id)
      job_context = @active_jobs[job_id]
      if job_context.nil?
        Wakame.log.warn("JOB ID #{job_id} was not running.")
        return
      end
      
      return if job_context[:complete_at]

      root_act = job_context[:root_action]

      walk_subactions = proc { |a|
        if a.status == :running && (a.target_thread && a.target_thread.alive?) && a.target_thread != Thread.current
          Wakame.log.debug "Raising CancelBroadcast exception: #{a.class} #{a.target_thread}(#{a.target_thread.status}), current=#{Thread.current}"
          # Broadcast the special exception to all
          a.target_thread.raise(CancelBroadcast, "It's broadcasted from #{a.class}")
          # IMPORTANT: Ensure the worker thread to handle the exception.
          #Thread.pass
        end
        a.subactions.each { |n|
          walk_subactions.call(n)
        }
      }

      begin
        Thread.critical = true
        walk_subactions.call(root_act)
      ensure
        Thread.critical = false
        # IMPORTANT: Ensure the worker thread to handle the exception.
        Thread.pass
      end
    end

    def run_action(action)
      job_context = @active_jobs[action.job_id]
      raise "The job session is killed.: job_id=#{action.job_id}" if job_context.nil?

      EM.next_tick {

        begin
          
          if job_context[:start_at].nil?
            job_context[:start_at] = Time.new
            ED.fire_event(Event::JobStart.new(action.job_id))
          end

          EM.defer proc {
            res = nil
            begin
              action.bind_thread(Thread.current)
              action.status = :running
              Wakame.log.debug("Start action : #{action.class.to_s} triggered by [#{action.trigger.class}]")
              ED.fire_event(Event::ActionStart.new(action))
              begin
                action.run
                action.completion_status = :succeeded
                Wakame.log.debug("Complete action : #{action.class.to_s}")
                ED.fire_event(Event::ActionComplete.new(action))
              end
            rescue CancelBroadcast => e
              Wakame.log.info("Received cancel signal: #{e}")
              action.completion_status = :canceled
              begin
                action.on_canceled
              rescue => e
                Wakame.log.error(e)
              end
              ED.fire_event(Event::ActionFailed.new(action, e))
              res = e
            rescue => e
              Wakame.log.debug("Failed action : #{action.class.to_s} due to #{e}")
              Wakame.log.error(e)
              action.completion_status = :failed
              begin
                action.on_failed
              rescue => e
                Wakame.log.error(e)
              end
              ED.fire_event(Event::ActionFailed.new(action, e))
              # Escalate the cancelation event to parents.
              unless action.parent_action.nil?
                action.parent_action.notify(e)
              end
              # Force to cancel the current job when the root action ignored the elevated exception.
              if action === job_context[:root_action]
                Wakame.log.warn("The escalated exception (#{e.class}) has reached to the root action (#{action.class}). Forcing to cancel the current job #{job_context[:job_id]}")
                cancel_action(job_context[:job_id]) #rescue Wakame.log.error($!)
              end
              res = e
            ensure
              action.status = :complete
              action.bind_thread(nil)
            end

            res
          }, proc { |res|
            unless @active_jobs.has_key?(job_context[:job_id])
              next
            end
            
            actary = []
            job_context[:root_action].walk_subactions {|a| actary << a }
            Wakame.log.debug(actary.collect{|a| {a.class.to_s=>a.status}}.inspect)

            if res.is_a?(Exception)
              job_context[:exception]=res
            end

            if actary.all? { |act| act.status == :complete }

              if actary.all? { |act| act.completion_status == :succeeded }
                ED.fire_event(Event::JobComplete.new(action.job_id))
              else
                ED.fire_event(Event::JobFailed.new(action.job_id, res))
              end

              job_context[:complete_at]=Time.now
              @job_history << job_context
              @active_jobs.delete(job_context[:job_id])
              service_cluster.lock_queue.quit(job_context[:job_id])
            end
          }
        rescue => e
          Wakame.log.error(e)
        end
      }
    end

  end
end
