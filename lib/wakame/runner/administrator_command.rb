
require 'uri'
require 'ext/uri'
require 'optparse'

require 'drb/drb'

require 'erb'

require 'wakame'
#require 'wakame/util'

$root_constants = Module.constants

module Wakame
  module Runner
    class AdministratorCommand

      attr_reader :options
      
      def initialize(args)
        @args = args.dup
        @options = {
          :command_server_uri => Wakame.config.drb_command_server_uri
        }
      end
      
      def parse(args=@args)
        args = args.dup
        
        comm_parser = OptionParser.new { |opts|
          opts.banner = "Usage: wakameadm [options] command [options]"
          
          opts.separator ""
          opts.separator "options:"
          opts.on( "-s", "--server DrbURI", "command server" ) {|str| @options[:command_server_uri] = str }
        }
        
        
        comm_parser.order!(args)
        @options.freeze
        return parse_subcommand(args)
      end
      
      def run
        subcommand = parse
        
        begin
          cmd_queue = DRbObject.new_with_uri(@options[:command_server_uri])
          #res = cmd_queue.send_cmd(Marshal.dump(subcommand))
          subcommand = cmd_queue.send_cmd(subcommand)
          #res = cmd_queue.send(subcommand.class.command_name)
        rescue => e
          STDERR.puts e
          exit 1
        end
        
        subcommand.print_result
      end
      
      private
      
      def parse_subcommand(args)
        @subcmd = args.shift
        if @subcmd.nil?
          fail "Please pass a sub command." 
        end

        subcommands = {}
        (Wakame::Command.constants - $root_constants).each { |c|
          const = Util.build_const("Wakame::Command::#{c}")
          if const.is_a?(Class)
            cmdobj = nil
            begin
              cmdobj = const.new
              raise '' unless cmdobj.kind_of?(Wakame::Command)
            rescue => e
              next
            end

            subcommands[cmdobj.class.command_name] = cmdobj
          end
        }

        subcommand = subcommands[@subcmd]
        fail "No such sub command: #{@subcmd}" if subcommand.nil?

        subcommand.parse(args)
        subcommand
#         opt_parser = subcommand[:opt_parser]
#         if opt_parser
#           sub_parser = OptionParser.new &opt_parser
#           sub_parser.order!(@tmp_args)
#         end
        
#         left_parser = [:left_parser]
#         if left_parser
#           begin
#             instance_eval(&left_parser)
#           rescue CommandArgumentError => e
#             fail e
#           end
#         end
      end

    end
  end
end
