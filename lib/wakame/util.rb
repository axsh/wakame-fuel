

require 'hmac-sha1'

module Wakame
  module Util

    def ssh_known_hosts_hash(hostname, key=nil)
      # Generate 20bytes random value
      key = Array.new(20).collect{rand(0xFF).to_i}.pack('c*') if key.nil?
      
      "|1|#{[key].pack('m').chop}|#{[HMAC::SHA1.digest(key, hostname)].pack('m').chop}"
    end

    module_function :ssh_known_hosts_hash

  end
end


module ThreadImmutable
  class IllegalCrossThreadMethodCall < StandardError; end


  module ClassMethods
    def thread_immutable_methods(*args)
      return if args.empty?
      
      args.each { |n|
        # Proc can not be passed a block due to 1.8's limitation. The following will work in 1.9.
        #um = instance_method(n) || next
        #define_method(n) { |*args, &blk|
        #  thread_check
        #  um.bind(self).call(*args, &blk)
        #}

        if method_defined?(n)
          alias_method "#{n}_no_thread_check", n.to_sym
          
          eval <<__E__
def #{n}(*args, &blk)
  thread_check
  #{n}_no_thread_check(*args, &blk)
end
__E__
        end
      }
    end
  end

  def self.included(klass)
    klass.extend ClassMethods
  end

#   def self.included(klass)
#     klass.class_eval {
#       _um_constructor = self.instance_method(:initialize)
#       if _um_constructor
#         define_method(:initialize) { |*args|
#           bind_thread
#           _um_constructor.bind(self).call(*args)
#         }
#       end
#     }
#   end

  #      def self.method_added2(name)
  #        if name == :initialize
  #
  #          _um_constructor = instance_method(:initialize)
  #          define_method(:initialize) { |*args|
  #            bind_thread
  #            _um_constructor.bind(self).call(*args)
  #          }
  #        end
  #      end


  def bind_thread(thread=Thread.current)
    @target_thread = thread
    puts "bound thread: #{@target_thread.inspect} to #{self.class} object"
  end

  def thread_check
    #puts "@target_thread == Thread.main : #{@target_thread == Thread.main}"
    raise "Thread is not bound." if @target_thread.nil?
    raise IllegalCrossThreadMethodCall unless target_thread?
  end

  def target_thread?
    @target_thread == Thread.current
  end

end
