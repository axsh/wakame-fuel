

$:.unshift File.dirname(__FILE__) + '/../lib'
require 'rubygems'

require 'test/unit'
require 'wakame'
require 'wakame/service.rb'

WAKAME_ROOT="#{File.dirname(__FILE__)}/.."

class TestService < Test::Unit::TestCase
  include Wakame::Service

  def test_dg
    c = WebCluster.new(nil)
    c.dg.each_level{ |s|
      p s
    }

    p c.dg.levels

    p c.dg.children(MySQL_Master)
    p c.dg.parents(Apache_APP)
  end


  def test_each_instance
    c = WebCluster.new(nil)
    c.launch
    c.each_instance(WebCluster::HttpLoadBalanceServer) { |svc|
      assert(svc.property.is_a?(Apache_LB))
    }
  end


  def test_vmspec
    spec = VmSpec.define {
      environment(:EC2) { |ec2|
        ec2.instance_type = 'm1.small'
        ec2.availability_zone = 'us-east-c1'
        ec2.security_groups << 'default'
      }
      
      environment(:StandAlone) {
      }
    }


    Wakame.config.vm_environment = :EC2
    p spec.current.attrs
    Wakame.config.vm_environment = :StandAlone
    p spec.current.attrs

    assert_raise(RuntimeError) {
      Wakame.config.vm_environment = :EC3
      spec.current.attrs
    }
  end
end
