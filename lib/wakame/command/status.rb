
class Wakame::Command::Status
  include Wakame::Command
  include Wakame::Service

  def run
    Wakame::StatusDB.barrier {
      res = {
        :cluster=>nil, 
        :agent_pool=>nil, 
        :agents=>{}, 
        :services=>{}, 
        :resources=>{},
        :cloud_hosts=>{}
      }
      cluster_id = master.cluster_manager.clusters.keys.first
      if cluster_id.nil?
        raise "There is no cluster setting"
      end

      cluster = ServiceCluster.find(cluster_id)
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

      cluster.cloud_hosts.keys.each { |id|
        res[:cloud_hosts][id]=CloudHost.find(id).dump_attrs
      }
#p res[:cluster]
      res
    }

  end
end
