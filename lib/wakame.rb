
require 'rubygems'

# For debugging
Thread.abort_on_exception = true 

module Wakame
  VERSION='0.3.1'
  autoload :Agent, 'wakame/agent'
  autoload :Master, 'wakame/master'
  autoload :Daemonize, 'wakame/daemonize'
  autoload :Util, 'wakame/util'
  autoload :Event, 'wakame/event'
  autoload :Service, 'wakame/service'
  autoload :Rule, 'wakame/rule'
  autoload :Graph, 'wakame/graph'
  autoload :Monitor, 'wakame/monitor'
  autoload :Actor, 'wakame/actor'
  autoload :Configuration, 'wakame/configuration'
  autoload :Logger, 'wakame/logger'
  autoload :Packets, 'wakame/packets'
  autoload :AMQPClient, 'wakame/amqp_client'
  autoload :EventDispatcher, 'wakame/event_dispatcher'
  autoload :Scheduler, 'wakame/scheduler'
  autoload :Command, 'wakame/command'
  autoload :CommandQueue, 'wakame/command_queue'
  autoload :Template, 'wakame/template'
  autoload :Trigger, 'wakame/trigger'
  #autoload :Initializer, 'wakame/initializer' # Do not autoload this class since the constant is used for the flag in bootstrap.

  def gen_id(str=nil)
    Util.gen_id(str)
  end

  def log
    Logger.log
  end

  module_function :gen_id, :log

  class << self
    def config
      Initializer.instance.configuration
    end

    def environment
      config.environment
    end

    def new_(class_or_str)
      Util.new_(class_or_str)
    end
  end

end
