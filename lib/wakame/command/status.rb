
class Wakame::Command::Status
  include Wakame::Command
  include Wakame::Service

  def run(rule)
    Wakame::StatusDB.barrier {
      res = {
        :cluster=>nil, 
        :agent_pool=>nil, 
        :agents=>{}, 
        :services=>{}, 
        :resources=>{},
        :hosts=>{}
      }

      cluster = ServiceCluster.find_all.first
      res[:cluster] = cluster.dump_attrs
      res[:agent_pool] = AgentPool.instance.dump_attrs

      AgentPool.instance.group_active.keys.each { |id|
        res[:agents][id] = Agent.find(id).dump_attrs
      }

      cluster.services.keys.each { |id|
        res[:services][id]=ServiceInstance.find(id).dump_attrs
      }

      cluster.resources.keys.each { |id|
        res[:resources][id]=Resource.find(id).dump_attrs
      }

      cluster.hosts.keys.each { |id|
        res[:hosts][id]=Host.find(id).dump_attrs
      }
#p res[:cluster]
      res
    }

  end
end
