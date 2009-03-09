

$:.unshift File.dirname(__FILE__) + '/../lib'
require 'rubygems'

require 'test/unit'
require 'wakame'
require 'wakame/configuration_template'
require 'wakame/service.rb'

WAKAME_ROOT="#{File.dirname(__FILE__)}/.."

class TestTemplate < Test::Unit::TestCase
  class DummyAgent
    def synchronize; end

    def agent_id
      'safasdfadsf'
    end

    def agent_ip
      '127.0.0.1'
    end

    def has_service_type?(n)
      false
    end
  end
  def test_render
    web = Wakame::Service::WebCluster.new(nil)
    web.launch

    agent = DummyAgent.new
    web.each_instance { |n|
      n.bind_agent(agent)

    }

    web.each_www { |n|
      t = Wakame::ConfigurationTemplate::ApacheTemplate.new(:www)
    
      t.pre_render
      t.render(n)
      puts t.sync_src
    }
    web.each_instance(Wakame::Service::Apache_LB) { |n|
      t = Wakame::ConfigurationTemplate::ApacheTemplate.new(:lb)
    
      t.pre_render
      t.render(n)
      puts t.sync_src
    }    
  end
end
