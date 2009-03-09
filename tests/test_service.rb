

$:.unshift File.dirname(__FILE__) + '/../lib'
require 'rubygems'

require 'test/unit'
require 'wakame'
require 'wakame/service.rb'

WAKAME_ROOT="#{File.dirname(__FILE__)}/.."

class TestService < Test::Unit::TestCase
  include Wakame::Service

  def test_dg
    c = WebCluster.new
    c.dg.bfs{ |s|
      p s
    }
  end


  def test_each_instance
    c = WebCluster.new(nil)
    c.launch
    c.each_instance(WebCluster::HttpLoadBalanceServer) { |svc|
      assert(svc.property.is_a?(Apache_LB))
    }
  end
end
