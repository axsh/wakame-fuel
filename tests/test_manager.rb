#!/usr/bin/ruby

$:.unshift File.dirname(__FILE__) + '/../lib'
require 'rubygems'

require 'test/unit'
require 'wakame/manager'
require 'wakame/service'
require 'wakame/packets'

class TestManager < Test::Unit::TestCase

  def setup
    puts "Start #{@method_name}"
  end
  
  def teardown
    puts "End #{@method_name}"
  end

  def test_manager_stop
    5.times {
      EM.run{
        Wakame::Master.stop
      }
    }
    5.times {
      EM.run{
        Wakame::Master.start
        EM.add_timer(1) { Wakame::Master.stop }
      }
    }
  end

  def test_command_queue
    EM.run {
      m = Wakame::Master.start

      jq = m.command_queue

      EM.next_tick {
        jq.send_cmd(Wakame::Manager::Commands::Nop.new)
        EM.add_timer(3) {
          Wakame::Master.stop
        }
      }
    }
  end

  def test_service_cluster
    sc = Wakame::ServiceCluster.new

    sc.add_service(Wakame::Service::Apache_WWW.new)
    sc.add_service(Wakame::Service::MySQL_Master.new)
    
    assert_equal(2, sc.size)
    sc.dg.bfs { |svc|
      puts "sg.dg.bfs " + svc.inspect
    }
  end


  class MockAgent
    def initialize
      # Do nothing
    end

    def agent_id
      'asdfasdfasdfasdfasdf'
    end
    def agent_ip
      '127.0.0.1'
    end
  end

  class DummyResponder
    include Wakame::AMQPClient
    include Wakame::QueueDeclare

    define_queue 'agent_command_dummy', 'agent_command'

    def initialize()
      connect {
        EM.next_tick {
          self.publish_to('ping', Marshal.dump(Wakame::Packets::Agent::Ping.new(MockAgent.new)))
          EM.add_periodic_timer(1) {
          #  self.publish_to('ping', Marshal.dump(Wakame::Packets::Agent::Ping.new(MockAgent.new)))
          }
        }


        add_subscriber('agent_command_dummy') { |data|
          packet = Marshal.load(data)
#p packet

          EM.defer proc {
            sleep 2.5
          }, proc {
            EM.next_tick {
              self.publish_to('agent_event', Marshal.dump(Wakame::Packets::Agent::EventResponse.new(MockAgent.new, Wakame::Event::ServiceStatusChanged.new(packet.instance_id, packet.property, Wakame::Service::STATUS_ONLINE))))
              puts "Sent Statuschangeevent : STATUS_ONLINE"
            }
          }
        }
      }
    end

  end

  def test_cmd_cluster_launch
    EM.run {
      master = Wakame::Master.start
      DummyResponder.start
      EM.add_timer(2){
        master.command_queue.send_cmd(Wakame::Packets::Command::ClusterLaunch.new('for_test'))
      }
      
      job_id=nil
      Wakame::EH.subscribe(Wakame::Event::ActionStart) { |event|
        job_id = event.job_id
      }

      Wakame::EH.subscribe(Wakame::Event::ActionComplete) { |event|
        puts "#{event.class.to_s} has been received from #{event.action.class.to_s}"
        assert_equal(job_id, event.job_id)
        assert_equal(Wakame::Manager::RuleEngine::ClusterResumeAction, event.action.class)
        
        EM.next_tick {
          Wakame::Master.stop
          DummyResponder.stop
        }
      }


    }
  end


  class DummyResponder2
    include Wakame::AMQPClient
    include Wakame::QueueDeclare

    def initialize()
      connect {
        EM.add_timer(1){
          self.publish_to('ping', Marshal.dump(Wakame::Packets::Agent::Ping.new(MockAgent.new)))
        }
      }
    end

  end


  def test_agent_monitor
    flag_statchanged=false
    flag_monitored=false

    EM.next_tick {
    Wakame::EH.subscribe(Wakame::Event::AgentStatusChanged) { |event|
      flag_statchanged = true
    }
    Wakame::EH.subscribe(Wakame::Event::AgentMonitored) { |event|
      flag_monitored = true
    }

    Wakame::EH.subscribe(Wakame::Event::AgentPong) { |event|
      puts "#{event.class.to_s} has been received from #{event.agent.agent_id}"
      assert_equal(1, master.agent_monitor.agents.size)
      
      EM.add_timer(1) {
        Wakame::Master.stop
        DummyResponder2.stop
      }
    }
    }

    EM.run {
      master = Wakame::Master.start
      DummyResponder2.start
EM.add_periodic_timer(1) {
next
          buf = ''
          buf << "<--- RUNNING THREADS --->\n"
          ThreadGroup::Default.list.each { |i|
            buf << "#{i.inspect} #{i[:name].to_s}\n"
          }
          buf << ">--- RUNNING THREADS ---<\n"
          puts buf
}

    }

    assert(flag_monitored)
    assert(flag_statchanged)
  end
  
  
end

