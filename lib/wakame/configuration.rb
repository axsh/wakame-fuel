

require 'ostruct'

module Wakame
  # System wide configuration parameters
  class Configuration < OpenStruct
    attr_reader :root_path
    alias :root :root_path

    PARAMS = {
      :master_local_agent_id => '__local__',
      :config_template_root => nil,
      :config_tmp_root => nil,
      :config_root => nil,
      :ssh_private_key => nil,
      :drb_command_server_uri => 'druby://localhost:12345',
      :vm_manipulation_class => nil,
      :vm_environment => nil,
      :amqp_server_uri => nil,
      :unused_vm_live_period => 60 * 10,
      :eventmachine_use_epoll => true
    }



    def initialize(default_set, root_path=nil)
      super(PARAMS)
      if root_path.nil?
        root_path = Object.const_defined?(:WAKAME_ROOT) ? WAKAME_ROOT : '../'
      end

      @root_path = root_path
      default_set.process(self)
    end
    

    def ssh_known_hosts
      File.join(self.config_root, "ssh", "known_hosts")
    end

    def config_tmp_root
      File.join(self.config_root, "tmp")
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
        config.vm_manipulation_class = 'Wakame::VmManipulator::EC2'
        config.vm_environment = :EC2

        config.ssh_private_key = '/home/wakame/config/root.id_rsa'

        config.aws_access_key = '1TE7T2475AY1YM8DZQ82'
        config.aws_secret_key = 'OyqnC6beLDN623TsZLIqNRHQ+agim3GqlZtzABir'
        config.ec2_ami_id = 'ami-8f9176e6'
      end
    end

    class StandAlone < DefaultSet
      def process(config)
        super(config)
        config.config_template_root = File.join(config.root, "config", "template")
        config.config_root = File.join('home', 'wakame', 'config')
        config.vm_manipulation_class = 'Wakame::VmManipulator::StandAlone'
        config.vm_environment = :StandAlone
        config.amqp_server_uri = 'amqp://localhost/'
      end
    end

  end





  class ConfigurationLoader
  end
  
  class RubyLoader < ConfigurationLoader
    def initialize(rb_path)
      @rb_path = rb_path
    end
    
    def load()
    end
    
  end
  
end
