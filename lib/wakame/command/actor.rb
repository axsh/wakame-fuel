
class Wakame::Command::Actor
  include Wakame::Command

  command_name='launch_cluster'

  def parse(args)
    raise "Not enugh number of arguments" if args.size < 2
    @agent_id = args.shift
    @path = args.shift
    @args = *args
  end

  def run(rule)
    request = rule.master.actor_request(@agent_id, @path, *@args).request
    request
  end


  def print_result
    
  end
end
