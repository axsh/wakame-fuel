
require 'uri'
require 'ext/uri'
require 'optparse'

require 'net/http'
require 'json'

require 'erb'

require 'wakame'
require 'pp'
$root_constants = Module.constants

module Wakame
  module Runner
    class AdministratorCommand
      attr_reader :options
     
      def initialize(args)
        @args = args.dup      
	@options = {
          :command_server_uri => Wakame.config.http_command_server_uri
        }
      end
      
      def parse(args=@args)
        args = args.dup
        
        comm_parser = OptionParser.new { |opts|
          opts.version = VERSION
          opts.banner = "Usage: wakameadm [options] command [options]"
          
          opts.separator ""
          opts.separator "options:"
          opts.on( "-s", "--server HttpURI", "command server" ) {|str| @options[:command_server_uri] = str }
        }
        

        comm_parser.order!(args)
        @options.freeze

        return parse_subcommand(args)
      end
      
      def run
        req = parse
        subcommand = req[:command]
        get_params = req[:command_server_uri]
        begin
          res = subcommand.run(get_params)
          res = JSON.parse(res)
        rescue => e
          res = STDERR.puts e
          exit 1
        end

        unless req[:json_print].nil?
          pp res
        else
          subcommand.print_result(res)
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
        request_params = {
          :command => subcommand,
          :command_server_uri => @options[:command_server_uri] + "?action=" + @subcmd + options[:query].to_s,
          :json_print => options[:json_print]
        }

        request_params
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

      def create_parser(args,&blk)
        parser = OptionParser.new(&blk)
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
      #opts.version = '2009.06'
      opts.banner = "Usage: launch_cluster [options]"
      opts.separator ""
      opts.separator "options:"
    }
    cmd = create_parser(args, &blk)
    options = {}
    unless cmd.version.nil?
      options[:query] = "&version=#{cmd.version}"
    end
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
      #opts.version = '2009.06'
      opts.banner = "Usage: shutdown_cluster"
      opts.separator ""
      opts.separator "options:"
    }
    cmd = create_parser(args, &blk)

    options = {}
    unless cmd.version.nil?
      options[:query] = "&version=#{cmd.version}"
    end
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
Cluster : <%= @service_cluster["name"].to_s %> (<%= @service_cluster["status"].to_s %>)
<%- @service_cluster["properties"].each { |prop, v| -%>
  <%= v["type"].to_s %> : <current=<%= v["instance_count"] %> min=<%= v["min_instances"] %>, max=<%= v["max_instances"] %>>
  <%- v["instances"].each { |id|
         svc_inst = @service_cluster["instances"][id]
  -%>
     <%= svc_inst["instance_id"] %> (<%= trans_svc_status(svc_inst["status"]) %>)
  <%- } -%>
<%- } -%>
<%- if @service_cluster["instances"].size > 0  -%>

Instances :
  <%- @service_cluster["instances"].each { |k, v| -%>
  <%= v["instance_id"] %> : <%= v["property"] %> (<%= trans_svc_status(v["status"]) %>)
    <%- if v["agent_id"] -%>
    On VM instance: <%= v["agent_id"]%>
    <%- end -%>
  <%- } -%>
<%- end -%>
<%- if @agent_monitor["registered"].size > 0 -%>

Agents :
  <%- @agent_monitor["registered"].each { |a| -%>
  <%= a["agent_id"] %> : <%= a["attr"]["local_ipv4"] %>, <%= a["attr"]["public_ipv4"] %> load=<%= a["attr"]["uptime"] %>, <%= (Time.now - a["last_ping_at"].to_i).to_i %> sec(s) <%= a["root_path"] %>(<%= a["status"] %>)
    <%- if !a["services"].nil? && a["services"].size > 0 && !@service_cluster["instances"].empty? -%>
    Services (<%= a["services"].size %>): <%= a["services"].collect{|id| @service_cluster["instances"][id]["property"] }.join(', ') %>
   <%- end -%>
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
    options = {}
    blk = Proc.new {|opts|
      #opts.version = "2009.06"
      opts.banner = "Usage: status [options]"
      opts.separator ""
      opts.separator "options:"
      opts.on("--dump"){|j| options[:json_print] = "yes" }
    }
    cmd = create_parser(args, &blk)

    unless cmd.version.nil?
      options[:query] = "&version=#{cmd.version}"
    end
    options
  end

  def run(options)
    res = uri(options)
    res
  end

  def print_result(res)
    @service_cluster = res[1]["data"]["service_cluster"]
    @agent_monitor = res[1]["data"]["agent_monitor"]
    puts ERB.new(STATUS_TMPL, nil, '-').result(binding)
  end

  private
  def trans_svc_status(stat)
    SVC_STATUS_MSG[stat]
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
      #opts.version = '2009.06'
      opts.banner = "Usage: action_status"
      opts.separator ""
      opts.separator "options:"
      opts.on("--dump"){|j| options[:json_print] = "yes" }
    }
    cmd = create_parser(args, &blk)

    #options = ""
    unless cmd.version.nil?
      options[:query] = "&version=#{cmd.version}"
    end
    options
  end

  def run(options)
    res = uri(options)
    res
  end

  def print_result(res)
    unless res[1].nil?
    @status = res[1]['data']
    end
    puts ERB.new(ACTION_STATUS_TMPL, nil, '-').result(binding)
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
    @options = {}
    @options[:query] = ""
    blk = Proc.new {|opts|
      #opts.version = '2009.06'
      opts.banner = "Usage: propagate_service"
      opts.separator ""
      opts.separator "options:"
      opts.on("-s SERVICE_NAME", "--service SERVICE_NAME"){|str| @options[:query] += "&service=#{str}"}
      opts.on("-n NUMBER", "--number NUMBER"){|i| @options[:query] += "&num=#{i}"}
    }
    cmd = create_parser(args, &blk)
    unless cmd.version.nil?
      @options[:query] += "&version=#{cmd.version}"
    end
    @options
  end

  def run(options)
    res = uri(options)
    res
  end

  def print_result(res)
    p res[0]["message"]
  end
end
