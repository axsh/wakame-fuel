
class Wakame::Monitor::Agent
  include Wakame::Monitor
  
  def initialize
    @status = STATUS_ONLINE
  end

  def send_ping(hash)
    publish_to('ping', Wakame::Packets::Agent::Ping.new(agent, hash[:attrs], hash[:actors], hash[:monitors]).marshal)
  end

  def setup(path)
    @timer = CheckerTimer.new(1) {
      send_ping(check)
    }
  end


  def check
    if Wakame.environment == :EC2
      require 'wakame/vm_manipulator'
      attrs = Wakame::VmManipulator::EC2::MetadataService.fetch_local_attrs
    else
      attrs = {:instance_id=>agent.agent_id}
    end

    res = {:attrs=>attrs, :monitors=>[], :actors=>[]}
    EM.barrier {
      agent.monitors.each { |key, m|
        res[:monitors] << {:class=>m.class.to_s}
      }
      agent.actors.each { |key, a|
        res[:actors] << {:class=>a.class.to_s}
      }
    }

    res
  end
end
