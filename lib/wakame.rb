

require 'rubygems'
require 'log4r'
require 'digest/sha1'
require 'shell'

require 'eventmachine'
require 'ext/eventmachine'

require 'wakame/configuration'
# For debugging
Thread.abort_on_exception = true 

Shell.debug = false
Shell.verbose = false

module Wakame
  VERSION='0.3.1'
  autoload :Agent, 'wakame/agent'
  autoload :Daemonize, 'wakame/daemonize'
  autoload :Util, 'wakame/util'
  autoload :Event, 'wakame/event'
  autoload :Service, 'wakame/service'
  autoload :Rule, 'wakame/rule'
  autoload :Graph, 'wakame/graph'

  def gen_id(str=nil)
    Digest::SHA1.hexdigest( (str.nil? ? rand.to_s : str) )
  end

  def log
    @log ||= begin
               #log = Logger.new((Wakame.root||Dir.pwd) / "log.log")
               out = ::Log4r::StdoutOutputter.new('stdout',
                                                  :formatter => Log4r::PatternFormatter.new(
                                                                                            :pattern => "%d %C[%l]: %M",
                                                                                            :date_format => "%Y/%m/%d %H:%M:%S"
                                                                                            )
                                                  )
               log = ::Log4r::Logger.new(File.basename($0.to_s))
               log.add(out)
               log
             end
  end

  def shell
    @sh ||= begin 
              sh = Shell.cd(Wakame.config.root)
              sh.system_path = %w[/bin /sbin /usr/bin /usr/sbin]
              sh
            end
    @sh
  end

  module_function :gen_id, :log, :shell

  class << self
    def config
      #@config ||= Wakame::Configuration.new(Wakame::Configuration::StandAlone.new)
      @config ||= Wakame::Configuration.new(Wakame::Configuration::EC2.new)
    end

    def str2const(name)
      name.to_s.split(/::/).inject(Object) {|c,name| c.const_get(name) }
    end

    
    def new_(class_or_str)
      if class_or_str.is_a? Class
        class_or_str.new
      else
        c = class_or_str.to_s.split(/::/).inject(Object) {|c,name| c.const_get(name) }
        c.new
      end
    end
  end

end

