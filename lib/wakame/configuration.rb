

require 'ostruct'

module Wakame
  # System wide configuration parameters
  class Configuration < OpenStruct

    PARAMS = {
      #:config_template_root => nil,
      #:config_tmp_root => nil,
      #:config_root => nil,
      :load_paths => [],
      :ssh_private_key => nil,
      :drb_command_server_uri => 'druby://localhost:12345',
      :vm_environment => nil,
      :amqp_server_uri => nil,
      :unused_vm_live_period => 60 * 10,
      :eventmachine_use_epoll => true
    }

    def initialize(env=WAKAME_ENV)
      super(PARAMS)
      if root_path.nil?
        root_path = Object.const_defined?(:WAKAME_ROOT) ? WAKAME_ROOT : '../'
      end

      @root_path = root_path
      #default_set.process(self)
    end

    def environment
      ::WAKAME_ENV.to_sym
    end
    
    def root_path
      ::WAKAME_ROOT
    end

    def ssh_known_hosts
      File.join(self.config_root, "ssh", "known_hosts")
    end

    def config_tmp_root
      File.join(self.config_root, "tmp")
    end

    def framework_root_path
      defined?(::WAKAME_FRAMEWORK_ROOT) ? ::WAKAME_FRAMEWORK_ROOT : "#{root_path}/vendor/wakame"
    end

    def framework_paths
      paths = %w(lib)

      paths.map{|dir| File.join(framework_root_path, dir) }.select{|path| File.directory?(path) }
    end
    # 
    class DefaultSet
      def process(config)
      end
    end

    class EC2 < DefaultSet
      def process(config)
        super(config)
        config.config_template_root = File.join(config.root, "config", "template")
        config.config_root = '/home/wakame/config'
        config.vm_environment = :EC2

        config.ssh_private_key = '/home/wakame/config/root.id_rsa'

        config.aws_access_key = ''
        config.aws_secret_key = ''
      end
    end

    class StandAlone < DefaultSet
      def process(config)
        super(config)
        config.config_template_root = File.join(config.root, "config", "template")
        config.config_root = File.join('home', 'wakame', 'config')
        config.vm_environment = :StandAlone
        config.amqp_server_uri = 'amqp://localhost/'
      end
    end

  end

end
