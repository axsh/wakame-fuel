
class Wakame::Command::Actor
  include Wakame::Command
  include Wakame::Service

  command_name='actor'

  def parse(args)
    raise "Not enugh number of arguments" if args.size < 2
  end

  def run
    agent = Agent.find(params[:agent_id])
    raise "Unknown agent: #{params[:agent_id]}" if agent.nil?
    raise "Invalid agent status (Not Online): #{agent.status} #{params[:agent_id]}" if agent.status != Agent::STATUS_ONLINE

    raise "Invalid actor path: #{params[:path]}" if params[:path].nil? || params[:path] == ''

    request = rule.master.actor_request(params[:agent_id], params[:path], *params[:args]).request
    request.wait
  end

end
