
module Wakame
  module Command
    class CommandArgumentError < StandardError; end

    def self.included(klass)
      klass.class_eval {
        class << self
          def command_name
            @command_name ||= Util.snake_case(self.to_s.split('::').last)
          end
          
          def command_name=(name)
            @command_name=name
          end
        end
      }
    end

    def options=(path)
      @options = path
    end

    def params
      @options
    end
    alias :options :params

    def run
    end

    protected
    def master
      Master.instance
    end

    def trigger_action(action)
      master.action_manager.trigger_action(action)
    end

    # Tentative utility method for 
    def service_cluster
      cluster_id = master.cluster_manager.clusters.first
      raise "There is no cluster loaded" if cluster_id.nil?

      Service::ServiceCluster.find(cluster_id)
    end
    alias :cluster :service_cluster
  end
end
