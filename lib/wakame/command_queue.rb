
require 'uri'
require 'thin'
require 'thread'
require 'json'

module Wakame
  class CommandQueue
    attr_reader :master

    def initialize(master)
      @master = master
      @queue = Queue.new
      @result_queue = Queue.new

      cmdsv_uri = URI.parse(Wakame.config.http_command_server_uri)

      @thin_server = Thin::Server.new(cmdsv_uri.host, cmdsv_uri.port, Adapter.new(self))
      @thin_server.threaded = true
      @thin_server.start
    end

    def shutdown
      @thin_server.stop
    end

    def deq_cmd()
      @queue.deq
    end

    def enq_result(res)
      @result_queue.enq(res)
    end

    def send_cmd(cmd)
      begin

        #cmd = Marshal.load(cmd)

        @queue.enq(cmd)

        ED.fire_event(Event::CommandReceived.new(cmd))

        return @result_queue.deq()
      rescue => e
        Wakame.log.error("#{self.class}:")
        Wakame.log.error(e)
      end
    end

  end
  class Adapter
  
    def initialize(command_queue)
      @command_queue = command_queue
    end
 
    def call(env)
Wakame.log.debug EM.reactor_thread?
      req = Rack::Request.new(env)
      request = req.get?()
        if request.to_s == "true"
          path = req.params()
          cname = path["action"].split("_")
          begin
            cmd = eval("Command::#{(cname.collect{|c| c.capitalize}).join}").new(path)
            command = @command_queue.send_cmd(cmd)

            if command.is_a?(Exception)
              status = 500

              body = json_encode(status, command.message)
            else
              status = 200
              body = json_encode(status, "OK", command)
            end
          rescue => e
            status = 404
            body = json_encode(status, e)
          end
        else
          status = 403
          body = json_encode(status, "Forbidden")
        end
      [ status, {'Content-Type' => 'text/javascript+json'}, body]
    end

    def json_encode(status, message, data=nil)
      if status == 200 && data.is_a?(Hash)
        body = [{:status=>status, :message=>message}, {:data=>data}].to_json
      else
        body = [{:status=>status, :message=>message}].to_json
      end
      body
    end
  end
end
