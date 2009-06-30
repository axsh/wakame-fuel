
require 'erb'

class Wakame::Command::ActionStatus
  include Wakame::Command

  def run(rule)
    walk_subactions = proc { |a, level|
      res = a.dump_attrs
      unless a.subactions.empty?
        res[:subactions] = a.subactions.collect { |s|
          walk_subactions.call(s, level + 1)
        }
      end
      res
    }

    EM.barrier {
      result = {}

      rule.master.service_cluster.rule_engine.active_jobs.each { |id, v|

        result[id]={:created_at=>v[:created_at], :src_rule=>v[:src_rule].class.to_s}
        
        result[id][:root_action] = walk_subactions.call(v[:root_action], 0)
        result[id][:root_action][:status] = v[:root_action].status
        result[id][:root_action][:subactions] = v[:root_action].subactions
      }
      
      @status = result
      @status
    }
  end
  private
  def tree_subactions(root, level=0)
    str= ("  " * level) + "#{root[:type]} (#{root[:status]})"
    unless root[:subactions].nil?
      root[:subactions].each { |a|
        str << "\n  "
        str << tree_subactions(a, level + 1)
      }
    end
    str
  end

end
