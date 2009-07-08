

$:.unshift(File.dirname(__FILE__) + '/../lib')
$:.unshift(File.dirname(__FILE__))

require 'setup_master.rb'

require 'wakame/service.rb'

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


  def test_queued_lock
    q = Wakame::Service::LockQueue.new(nil)
    q.set('Apache', '12345')
    q.set('MySQL', '12345')
    q.set('MySQL2', '12345')
    q.set('Apache', '6789')
    q.set('LB', '6789')
    assert_equal(:runnable, q.test('12345'))
    assert_equal(:wait, q.test('6789'))
    assert_equal(:pass, q.test('unknown'))
    #puts q.inspect
    q.quit('12345')
    assert_equal(:pass, q.test('12345'))
    assert_equal(:runnable, q.test('6789'))
    #puts q.inspect
    q.set('Apache', '2345')
    q.set('LB', '2345')
    q.set('MySQL', '2345')
    assert_equal(:runnable, q.test('6789'))
    assert_equal(:wait, q.test('2345'))
    q.quit('2345')
    assert_equal(:runnable, q.test('6789'))
    assert_equal(:pass, q.test('2345'))
  end
end
