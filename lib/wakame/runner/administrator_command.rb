
require 'uri'
require 'cgi'
require 'optparse'
require 'net/http'
require 'json'
require 'erb'
require 'wakame'

#require 'openssl'
#require 'base64'

$root_constants = Module.constants

module Wakame
  module Runner
    class AdministratorCommand
      attr_reader :options
     
      def initialize(args)
        @args = args.dup      
	@options = {
          :command_server_uri => Wakame.config.http_command_server_uri,
          :json_print => false
        }
	@public_key = "1234567890"
      end
      
      def parse(args=@args)
        args = args.dup
        
        comm_parser = OptionParser.new { |opts|
          opts.version = Wakame::VERSION
          opts.banner = "Usage: wakameadm [options] command [options]"
          
          opts.separator ""
          opts.separator "options:"
          opts.on( "-s", "--server HttpURI", "command server" ) {|str| @options[:command_server_uri] = str }
          opts.on("--dump", "Print corresponded message body for debugging"){|j| @options[:json_print] = true }
        }
        

        comm_parser.order!(args)
        @options.freeze

        return parse_subcommand(args)
      end
      
      def run
        req = parse
        subcommand = req[:command]

	if Wakame.config.enable_authentication == "true"
	  get_params = authentication(req[:command_server_uri], req[:query_string])
	else
	  get_params = req[:command_server_uri] + req[:query_string]
	end
        begin
          res = subcommand.run(get_params)
          res = JSON.parse(res)
        rescue => e
          res = STDERR.puts e
          exit 1
        end

        if @options[:json_print]
	  require 'pp' 
          pp res
        else
          exit_code = 1
          case res[0]["status"]
          when 404
            STDERR.puts "Command Error: #{res[0]["message"]}"
          when 403
            STDERR.puts "Authentication Error: #{res[0]["message"]}"
          when 500
            STDERR.puts "Server Error: #{res[0]["message"]}"
          else
	    subcommand.print_result(res)
            exit_code = 0
          end

          exit exit_code
        end
      end
      
      private
      
      def parse_subcommand(args)
        @subcmd = args.shift
        if @subcmd.nil?
          fail "Please pass a sub command." 
        end
        subcommands = {}
        (Wakame::Cli::Subcommand.constants - $root_constants).each { |c|
          const = Util.build_const("Wakame::Cli::Subcommand::#{c}")
          if const.is_a?(Class)
            cmdobj = nil
            begin
              cmdobj = const.new
              raise '' unless cmdobj.kind_of?(Wakame::Cli::Subcommand)
            rescue => e
              next
            end
            subcommands[cmdobj.class.command_name] = cmdobj
          end
        }
        subcommand = subcommands[@subcmd]
        fail "No such sub command: #{@subcmd}" if subcommand.nil?

        options = subcommand.parse(args)
	query_string = CGI.escape('action') + "=" + CGI.escape(@subcmd) + options[:query].to_s
        request_params = {
          :command => subcommand,
          :command_server_uri => @options[:command_server_uri] + "?",
	  :query_string => query_string
        }

        request_params
      end

      def authentication(uri, query)
        key = @public_key
	req = query + "&" + CGI.escape('timestamp') + "=" + CGI.escape(Time.now.utc.strftime("%Y%m%dT%H%M%SZ"))
	hash = OpenSSL::HMAC::digest(OpenSSL::Digest::SHA256.new, key, req)
	sign = uri.to_s + req.to_s + "&signature=" + Base64.encode64(hash).gsub(/\+/, "").gsub(/\n/, "").to_s
	sign
      end
    end
  end

  module Cli
    module Subcommand
      class CommandArgumentError < StandardError; end

      def self.included(klass)
        klass.class_eval {
          class << self
            def command_name
              @command_name ||= Util.snake_case(self.to_s.split('::').last)
            end

            def command_name=(name)
              @command_name=name
            end
          end
        }
      end

      def parse(args)
      end

      def run(options)
      end

      def print_result(res)
      end

      
      def create_parser(args, &blk)
        parser = OptionParser.new { |opts|
          blk.call(opts) if blk
        }
        parser.order!(args)
        parser
      end

      def uri(options)
        uri = options
        res = Net::HTTP.get(URI.parse("#{uri}"))
        return res
      end

      def summary
      end
    end
  end
end

class Wakame::Cli::Subcommand::LaunchCluster
  include Wakame::Cli::Subcommand

  #command_name = 'launch_cluster'
  def parse(args)
    blk = Proc.new {|opts|
      opts.banner = "Usage: launch_cluster [options]"
      opts.separator ""
      opts.separator "options:"
    }
    cmd = create_parser(args, &blk)
    options = {}
    options
  end

  def run(options)
    res = uri(options)
    res
  end

  def print_result(res)
    p res[0]["message"]
  end
end

class Wakame::Cli::Subcommand::ShutdownCluster
  include Wakame::Cli::Subcommand

  def parse(args)
    blk = Proc.new {|opts|
      opts.banner = "Usage: shutdown_cluster"
      opts.separator ""
      opts.separator "options:"
    }
    cmd = create_parser(args, &blk)
    options = {}
    options
  end

  def run(options)
    res = uri(options)
    res
  end

  def print_result(res)
    p res[0]["message"]
  end
end

class Wakame::Cli::Subcommand::Status
  include Wakame::Cli::Subcommand

  STATUS_TMPL = <<__E__
Cluster : <%= cluster["name"].to_s %> (<%= cluster_status_msg(cluster["status"]) %>)
<%- cluster["resources"].keys.each { |res_id|
  resource = body["resources"][res_id]
-%>
  <%= resource["class_type"] %> : <current=<%= resource["instance_count"] %> min=<%= resource["min_instances"] %>, max=<%= resource["max_instances"] %><%= resource["require_agent"] ? "" : ", AgentLess" %>>
  <%- resource["services_ref"].each { |svc_inst| -%>
     <%= svc_inst["id"] %> (<%= svc_status_msg(svc_inst["status"]) %>)
  <%- } -%>
<%- } -%>
<%- if cluster["services"].size > 0  -%>

Instances :
  <%- cluster["services"].keys.each { |svc_id| 
    svc = body["services"][svc_id]
  -%>
  <%= svc_id %> : <%= svc["resource_ref"]["class_type"] %> (<%= svc_status_msg(svc["status"]) %>)
    <%- if svc["agent_ref"] -%>
    On VM: <%= svc["agent_ref"]["id"] %>
    <%- end -%>
  <%- } -%>
<%- end -%>
<%- if agent_pool["group_active"].size > 0 -%>

Agents :
  <%- agent_pool["group_active"].keys.each { |agent_id|
  a = body["agents"][agent_id]
  -%>
  <%= a["id"] %> : <%= a["vm_attr"]["local_ipv4"] %>, <%= a["vm_attr"]["public_ipv4"] %>, <%= (Time.now - Time.parse(a["last_ping_at"])).to_i %> sec(s), placement=<%= a["vm_attr"]["availability_zone"] %> (<%= svc_status_msg(a["status"]) %>)
   <%- if a["reported_services"].size > 0 && !cluster["services"].empty? -%>
    Services (<%= a["reported_services"].size %>): <%= a["reported_services"].keys.collect{ |svc_id| body["services"][svc_id]["resource_ref"]["class_type"] }.join(', ') %>
   <%- end -%>
  <%- } -%>
<%- end -%>
__E__

  SVC_STATUS_MSG={
    Wakame::Service::STATUS_END=>'Terminated',
    Wakame::Service::STATUS_INIT=>'Inialized',
    Wakame::Service::STATUS_OFFLINE=>'Offline',
    Wakame::Service::STATUS_ONLINE=>'ONLINE',
    Wakame::Service::STATUS_UNKNOWN=>'Unknown',
    Wakame::Service::STATUS_FAIL=>'Fail',
    Wakame::Service::STATUS_STARTING=>'Starting...',
    Wakame::Service::STATUS_STOPPING=>'Stopping...',
    Wakame::Service::STATUS_RELOADING=>'Reloading...',
    Wakame::Service::STATUS_MIGRATING=>'Migrating...'
  }

  CLUSTER_STATUS_MSG={
    Wakame::Service::ServiceCluster::STATUS_OFFLINE=>'Offline',
    Wakame::Service::ServiceCluster::STATUS_ONLINE=>'Online',
    Wakame::Service::ServiceCluster::STATUS_PARTIAL_ONLINE=>'Partial Online'
  }

  def parse(args)
    options = {}
    blk = Proc.new {|opts|
      opts.banner = "Usage: status [options]"
      opts.separator ""
      opts.separator "options:"
    }
    cmd = create_parser(args, &blk)
    options
  end

  def run(options)
    res = uri(options)
    res
  end

  def print_result(res)
    require 'time'
    body = res[1]["data"]
    map_ref_data(body)

    cluster = body["cluster"]
    agent_pool = body["agent_pool"]
    puts ERB.new(STATUS_TMPL, nil, '-').result(binding)
  end

  private
  def svc_status_msg(stat)
    SVC_STATUS_MSG[stat]
  end

  def cluster_status_msg(stat)
    CLUSTER_STATUS_MSG[stat]
  end

  def map_ref_data(body)
    # Create reference for ServiceInstance to assciated object.(1:1)
    body["services"].each { |k,v|
      v["resource_ref"] = body["resources"][v["resource_id"]]
      v["host_ref"] = body["hosts"][v["host_id"]]
      if v["host_ref"]
        v["agent_ref"] = body["agents"][v["host_ref"]["agent_id"]]
      end
    }

    # Create reference for Resource object to ServiceInstance array. (1:N)
    body["resources"].each { |res_id,v|
      v["services_ref"] = body["services"].values.find_all{|v| v["resource_id"] == res_id }.map{|v| v}
    }
  end
end

class Wakame::Cli::Subcommand::ActionStatus
  include Wakame::Cli::Subcommand

  ACTION_STATUS_TMPL= <<__E__
Running Actions : <%= @status.size %> action(s)
<%- if @status.size > 0 -%>
<%- @status.each { |id, j| -%>
JOB <%= id %> :
  start : <%= j["created_at"] %>
  <%= tree_subactions(j["root_action"]) %>
<%- } -%>
<%- end -%>
__E__

  def parse(args)
    options = {}
    blk = Proc.new {|opts|
      opts.banner = "Usage: action_status"
      opts.separator ""
      opts.separator "options:"
    }
    cmd = create_parser(args, &blk)
    options
  end

  def run(options)
    res = uri(options)
    res
  end

  def print_result(res)
    if res[1]["data"].nil?
      p res[0]["message"]
    else
      @status = res[1]['data']
      puts ERB.new(ACTION_STATUS_TMPL, nil, '-').result(binding)
    end
  end

  private
  def tree_subactions(root, level=0)
    str= ("  " * level) + "#{root["type"]} (#{root["status"]})"
    unless root["subactions"].nil?
      root["subactions"].each { |a|
        str << "\n  "
        str << tree_subactions(a, level + 1)
      }
    end
    str
  end
end

class Wakame::Cli::Subcommand::PropagateService
  include Wakame::Cli::Subcommand

  def parse(args)
    params = {}
    cmd = create_parser(args) {|opts|
      opts.banner = 'Usage: propagate_service [options] "Service ID"'
      opts.separator('Options:')
      opts.on('-h HOST_ID', '--host HOST_ID', String, "Number (>0) to propagate the specified service."){ |i| params["number"] = i.to_i }
      opts.on('-n NUMBER', '--number NUMBER', Integer, "Number (>0) to propagate the specified service."){ |i| params["number"] = i.to_i }
    }
    raise "Unknown Service ID: #{args}" unless args.size > 0
    params[:service_id] = args.shift

    options = {}
    options[:query] = "&" + params.collect{|k,v| "#{CGI.escape(k.to_s)}=#{CGI.escape(v)}"}.join("&")
    options
  end

  def run(options)
    res = uri(options)
    res
  end

  def print_result(res)
    p res[0]["message"]
  end
end

class Wakame::Cli::Subcommand::PropagateResource
  include Wakame::Cli::Subcommand

  def parse(args)
    params = {}
    create_parser(args) {|opts|
      opts.banner = 'Usage: propagate_resource [options] "Resource Name" "Host ID"'
      opts.separator("  Resource Name: ....")
      opts.separator("  Host ID: ....")
      opts.separator("  ")
      opts.separator("  Options:")
      opts.on("-n NUMBER", "--number NUMBER", Integer, "Number (>0) to propagate the specified resource."){|i| params["number"] = i}
    }
    raise "Unknown Resource Name: #{args}" unless args.size > 0
    params["resource"] = args.shift

    raise "Unknown Host ID: #{args}" unless args.size > 0
    params["host_id"] = args.shift

    options = {}
    options[:query] = "&" + params.collect{|k,v| "#{CGI.escape(k.to_s)}=#{CGI.escape(v)}"}.join("&")
    options
  end

  def run(options)
    res = uri(options)
    res
  end

  def print_result(res)
    p res[0]["message"]
  end
end

class Wakame::Cli::Subcommand::StopService
  include Wakame::Cli::Subcommand

  def parse(args)
    params = {}
    blk = Proc.new {|opts|
      opts.banner = "Usage: stop_service [options] \"Service ID\""
      opts.separator ""
      opts.separator "options:"
      opts.on("-i INSTANCE_ID", "--instance INSTANCE_ID"){|i| params[:service_id] = i}
      opts.on("-s SERVICE_NAME", "--service SERVICE_NAME"){|str| params[:service_name] = str}
      opts.on("-a AGENT_ID", "--agent AGENT_ID"){|i| params[:agent_id] = i}
    }
    cmd = create_parser(args, &blk)
    options = {}
    options[:query] = "&" + params.collect{|k,v| CGI.escape(k.to_s) + "=" + CGI.escape(v)}.join("&")
    options
  end

  def run(options)
    res = uri(options)
    res
  end

  def print_result(res)
    p res[0]["message"]
  end
end

class Wakame::Cli::Subcommand::MigrateService
  include Wakame::Cli::Subcommand
  def parse(args)
    params = {}
     blk = Proc.new {|opts|
      opts.banner = "Usage: migrate_service [options] \"Service ID\""
      opts.separator ""
      opts.separator "options:"
      opts.on("-a Agent ID", "--agent Agent ID"){ |i| params[:agent_id] = i}
    }
    cmd = create_parser(args, &blk)
    service_id = args.shift || abort("[ERROR]: Service ID was not given")
    params[:service_id] = service_id
    options = {}
    options[:query] = "&" + params.collect{|k,v| "#{CGI.escape(k.to_s)}=#{CGI.escape(v)}"}.join("&")
    options
  end

  def run(options)
    res = uri(options)
    res
  end

  def print_result(res)
    p res[0]["message"]
  end
end

class Wakame::Cli::Subcommand::ShutdownVm
  include Wakame::Cli::Subcommand

  def parse(args)
    params = {}
    blk = Proc.new {|opts|
      opts.banner = "Usage: shutdown_vm [options] \"Agent ID\""
      opts.separator ""
      opts.separator "options:"
      opts.on("-f", "--force"){|str| params[:force] = "yes"}
    }
    cmd = create_parser(args, &blk)
    agent_id = args.shift || abort("[ERROR]: Agent ID was not given")
    params[:agent_id] = agent_id
    options = {}
    options[:query] = "&" + params.collect{|k,v| CGI.escape(k.to_s) + "=" + CGI.escape(v)}.join("&")
    options
  end

  def run(options)
    res = uri(options)
    res
  end

  def print_result(res)
    p res[0]["message"]
  end
end

class Wakame::Cli::Subcommand::LaunchVm
  include Wakame::Cli::Subcommand

  def parse(args)
    blk = Proc.new {|opts|
      opts.banner = "Usage: launch_vm"
      opts.separator ""
      opts.separator "options:"
    }
    cmd = create_parser(args, &blk)
    options = {}
    options
  end

  def run(options)
    res = uri(options)
    res
  end

  def print_result(res)
    p res[0]["message"]
  end
end

class Wakame::Cli::Subcommand::ReloadService
  include Wakame::Cli::Subcommand

  def parse(args)
    params = {}
    blk = Proc.new {|opts|
      opts.banner = "Usage: ReloadService [options] \"Service NAME\""
      opts.separator ""
      opts.separator "options:"
    }
    cmd = create_parser(args, &blk)
    service_name = args.shift || abort("[ERROR]: Service NAME was not given")
    params[:service_name] = service_name
    options = {}
    options[:query] = "&" + params.collect{|k,v| CGI.escape(k.to_s) + "=" + CGI.escape(v)}.join("&")
    options
  end

  def run(options)
    res = uri(options)
    res
  end

  def print_result(res)
    p res[0]["message"]
  end
end

class Wakame::Cli::Subcommand::AgentStatus
  include Wakame::Cli::Subcommand

STATUS_TMPL = <<__E__
Agent :<%= @agent["agent_id"]%> load=<%= @agent["attr"]["uptime"]%>, <%= (Time.now - Time.parse(@agent["last_ping_at"])).to_i%> sec(s), placement=<%= @agent["attr"]["availability_zone"]%><%= @agent["root_path"] %> (<%= trans_svc_status(@agent["status"]) %>)
  Instance ID : <%= @agent["attr"]["instance_id"]%>
  AMI ID : <%= @agent["attr"]["ami_id"]%>
  Public DNS Name : <%= @agent["attr"]["public_hostname"]%>
  Private DNS Name : <%= @agent["attr"]["local_hostname"]%>
  Instance Type : <%= @agent["attr"]["instance_type"]%>
  Availability Zone : <%= @agent["attr"]["availability_zone"]%>

<%- if !@agent["services"].nil? && @agent["services"].size > 0 -%>
Services (<%= @agent["services"].size%>):
  <%- @agent["services"].each {|id| -%>
      <%= @service_cluster["instances"][id]["instance_id"]%> : <%= @service_cluster["instances"][id]["property"]%> (<%= trans_svc_status(@service_cluster["instances"][id]["status"])%>)
  <%- } -%>
<%- end -%>
__E__

  SVC_STATUS_MSG={
    Wakame::Service::STATUS_OFFLINE=>'Offline',
    Wakame::Service::STATUS_ONLINE=>'ONLINE',
    Wakame::Service::STATUS_UNKNOWN=>'Unknown',
    Wakame::Service::STATUS_FAIL=>'Fail',
    Wakame::Service::STATUS_STARTING=>'Starting...',
    Wakame::Service::STATUS_STOPPING=>'Stopping...',
    Wakame::Service::STATUS_RELOADING=>'Reloading...',
    Wakame::Service::STATUS_MIGRATING=>'Migrating...',
  }

  def parse(args)
    params = {}
    blk = Proc.new {|opts|
      opts.banner = "Usage: AgentStatus [options] \"Agent ID\""
      opts.separator ""
      opts.separator "options:"
    }
    cmd = create_parser(args, &blk)
    agent_id = args.shift || abort("[ERROR]: Agent ID was not given")
    params[:agent_id] = agent_id
    options = {}
    options[:query] = "&" + params.collect{|k,v| CGI.escape(k.to_s) + "=" + CGI.escape(v)}.join("&")
    options
  end

  def run(options)
    res = uri(options)
    res
  end

  def print_result(res)
    require 'time'
    @agent = res[1]["data"]["agent_status"]
    @service_cluster = res[1]["data"]["service_cluster"]
    puts ERB.new(STATUS_TMPL, nil, '-').result(binding)
  end

  private
  def trans_svc_status(stat)
    SVC_STATUS_MSG[stat]
  end
end
