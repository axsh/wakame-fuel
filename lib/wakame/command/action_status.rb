
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

      rule.rule_engine.active_jobs.each { |id, v|

        result[id]={:created_at=>v[:created_at], :src_rule=>v[:src_rule].class.to_s}        
        result[id][:root_action] = walk_subactions.call(v[:root_action], 0)

      }
      @status = result
      @status
    }
  end
end
