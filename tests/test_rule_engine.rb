

$:.unshift File.dirname(__FILE__) + '/../lib'
require 'rubygems'

require 'test/unit'
require 'wakame'
require 'wakame/rule.rb'

WAKAME_ROOT="#{File.dirname(__FILE__)}/.."


class TestRuleEngine < Test::Unit::TestCase
  include Wakame::Rule
  
  class Action1 < Action
    def run
      trigger_action(Action2.new)
      flush_subactions
    end
  end
  class Action2 < Action
    def run
      act3 = Action3.new
      trigger_action(act3)
      flush_subactions
    end
  end
  class Action3 < Action
    def run
      puts "sleeping(2)..."
      sleep 2
    end
  end

  class Rule1 < Rule
    def register_hooks
      trigger_action(Action1.new)
    end
  end

  class DummyMaster
  end

  def test_nested_actions
    EM.run {
      engine = RuleEngine.new(Wakame::Service::ServiceCluster.new(Object.new))
      engine.register_rule(Rule1.new)
      EM.add_timer(5) { EM.stop }
    }
  end

  def test_each_subaction
    EM.run {
      engine = RuleEngine.new(Wakame::Service::ServiceCluster.new(Object.new))
      engine.register_rule(Rule1.new)
      EM.add_timer(1) {
      engine.active_jobs.each { |k, v|
        v[:root_action].walk_subactions {|a|
          puts a
        }
      }

      }
      EM.add_timer(5) { EM.stop }
    }
  end


  class Rule2 < Rule
    def register_hooks
      act1 = Action1.new
      job_id = trigger_action(act1)
      puts job_id

      EM.add_timer(1){
        rule_engine.cancel_action(job_id) 
      }
    end
  end

  def test_cancel_action
    EM.run {
      engine = RuleEngine.new(Wakame::Service::ServiceCluster.new(Object.new))
      engine.register_rule(Rule2.new)
      EM.add_timer(5) { EM.stop }
    }
  end


  class Action4 < Action
    def run
      trigger_action(Action1.new)

      trigger_action(FailAction1.new)

      flush_subactions
    end
  end

  class FailAction1 < Action
    def run
      trigger_action(Action1.new)
      raise StandardError
    end
  end

  class Rule3 < Rule
    def register_hooks
      trigger_action(Action4.new)
    end
  end

  def test_cancel_escalation
    EM.run {
      engine = RuleEngine.new(Wakame::Service::ServiceCluster.new(Object.new))
      engine.register_rule(Rule3.new)
      EM.add_timer(10) { EM.stop }
    }
  end

end
