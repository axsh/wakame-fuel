#!/usr/bin/ruby

$:.unshift File.dirname(__FILE__) + '/../lib'
require 'rubygems'

require 'test/unit'
require 'wakame/agent'

class TestAgent < Test::Unit::TestCase

  def setup
    puts "Start #{@method_name}"
  end
  
  def teardown
    puts "End #{@method_name}"
  end

  def test_agent_stop
    5.times {
      EM.run{
        Wakame::Agent.stop
      }
    }
    5.times {
      EM.run{
        Wakame::Agent.start
        assert_equal(Wakame::Agent, Wakame::Agent.start.class) # Get cached instance returned
        EM.add_timer(1) { Wakame::Agent.stop }
      }
    }
  end

  DUMMY_INSTANCE_ID='dummy_instance_id'
  class DummyService < Wakame::Service::Property
    attr_reader :check_count
    def initialize(check_time=0.3)
      super(check_time)
      @check_count = 0
    end

    def start
      @start_time ||= Time.now
      #log.debug "/etc/init.d/apache start"
      puts "/etc/init.d/apache start"
      sleep 2
    end

    def check
      return false if @start_time.nil?
      @check_count += 1
      #log.debug "checking... #{Time.now - @start_time} : #{Thread.current.inspect}"
      puts "checking... #{Time.now - @start_time} : #{Thread.current.inspect}"

      sleep 0.5

      return Time.now - @start_time > 4.5 ? true : false
    end

    def stop
      #log.debug "/etc/init.d/apache stop"
      puts "/etc/init.d/apache stop"
      @start_time = nil
      sleep 2
    end
  end


  ## This test dies when the test ran after another test.
  # The test process stops at sleep() in DummyService#check(). The hang seems to be occured in EM's C backend though check() method runs in EM.defer thread which is Ruby thread.
  def test_service_monitor
    status_changed_flag=0
    Wakame::EH.reset
    EM.run {
      monitor = Wakame::ServiceMonitor.new
      Wakame::EH.subscribe(Wakame::Event::ServiceStatusChanged) { |event|
        assert_equal(DUMMY_INSTANCE_ID, event.instance_id)
        status_changed_flag=1
      }
      dummy = Wakame::ServiceRunner.new(DUMMY_INSTANCE_ID, DummyService.new(2))
      monitor.register(dummy)

      Wakame::EH.subscribe(Wakame::Event::ServiceOnline) { |event|

        count = 0
        monitor.monitors {|i|
          count+=1
        }

        assert(dummy.property.check_count > 0)
        assert_equal(1, count)
        assert_equal(DUMMY_INSTANCE_ID, event.instance_id)
        EM.next_tick {
          EM.stop
        }
      }

      
      EM.defer proc { dummy.start }
      # Do not use EM.next_tick{ sleep 5 }. This holds EM's main thread up. 
      # Run DummyService#check() for 5 secs
    }
  end


  def test_send_cmd
    EM.run {
      agent = Wakame::Agent.start
      EM.next_tick {
        agent.send_cmd(Wakame::Packets::Agent::Nop.new)
        Wakame::Agent.stop
      }
    }
  end


  def test_agent_cmd_service_start
    EM.run {
      agent = Wakame::Agent.start
      EM.next_tick {
        dummy = DummyService.new(2)
        agent.send_cmd(Wakame::Packets::Agent::ServiceStart.new(DUMMY_INSTANCE_ID, dummy))
        EM.add_timer(10){ 
          assert_equal(Wakame::Service::STATUS_UP, agent.svc_mon[DUMMY_INSTANCE_ID].status)
          Wakame::Agent.stop
        }
      }
    }
  end
end
