
$:.unshift File.dirname(__FILE__) + '/../lib'
require 'rubygems'

require 'test/unit'
require 'uri'
require 'ext/uri'

class TestUriAMQP < Test::Unit::TestCase
  def test_parse
    
    assert_equal('amqp://localhost/', URI.parse('amqp://localhost/').to_s)
    assert_equal('amqp://localhost:1122/', URI.parse('amqp://localhost:1122/').to_s)
    assert_equal('amqp://127.0.0.1/vvv', URI.parse('amqp://127.0.0.1/vvv').to_s)
    
    u=URI.parse('amqp://127.0.0.1/vvv')
    assert_equal('/vvv', u.vhost)
  end
end
