

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
    #puts "bound thread: #{@target_thread.inspect} to #{self.class} object"
  end

  def thread_check
    #puts "@target_thread == Thread.main : #{@target_thread == Thread.main}"
    raise "Thread is not bound." if @target_thread.nil?
    raise IllegalCrossThreadMethodCall unless target_thread?
  end

  def target_thread?(t=Thread.current)
    @target_thread == t
  end


  def target_thread
    @target_thread
  end

end



module AttributeHelper

  PRIMITIVE_CLASSES=[NilClass, TrueClass, FalseClass, Numeric, String, Time, Symbol]

  module ClassMethods
    def attr_attributes
      @attr_attributes ||= {}
    end

    def def_attribute(name, default_value=nil)
      attr_attributes[name.to_sym]= {:default=>default_value}
      class_eval <<-__E__
      def #{name}=(v)
        @#{name}=v
      end
        
      def #{name}
        if @#{name}.nil?
          retrieve_attr_attribute { |a|
            if a.has_key?(:#{name})
              @#{name} = a[:#{name}][:default]
              break
            end
          }
        end
        @#{name}
      end

      public :#{name}, :#{name}=
      __E__
    end
    
  end

  private
  def self.included(klass)
    klass.extend ClassMethods
  end


  public
  def dump_attrs(root=nil)
    if root.nil? 
      root = self
    end

    return dump_internal(root)
  end
  #thread_immutable_method :dump_attrs if self.kind_of?(ThreadImmutable)
  #module_function :dump_attrs


  private
  def retrieve_attr_attribute(&blk)
    self.class.ancestors.each { |klass|
      blk.call(klass.attr_attributes) if klass.include?(AttributeHelper)
    }
  end

  def dump_internal(root)
    case root
    when AttributeHelper
      t={}
      t[:type] = root.class.to_s

      retrieve_attr_attribute { |a|
        a.each_key {|k| t[k] = dump_internal(root.__send__(k.to_sym)) }
      }
      t
    when Array
      root.collect { |a| dump_internal(a) }
    when Hash
      t={}
      root.each {|k,v| t[k] = dump_internal(v) }
      t
    else
      if PRIMITIVE_CLASSES.any?{|p| root.kind_of?(p) }
        root
      #elsif root.respond_to?(:dump_attrs)
        #dump_internal(root.dump_attrs)
      else
        raise TypeError, "#{root.class} does not support to dump attributes"
      end
    end
  end

end


class SortedHash < Hash
  def initialize
    @keyorder=[]
  end
  

  def store(key, value)
    raise TypeError, "#{key} is not Comparable" unless key.kind_of?(Comparable)
    if has_key?(key)
      ret = super(key, value)
    else
      ret = super(key, value)
      @keyorder << key
      @keyorder.sort!
      
    end
    ret
  end

  def []=(key, value)
    store(key, value)
  end

  def delete(key, &blk)
    if has_key?(key)
      @keyorder.delete(key)
      super(key, &blk)
    end
  end

  def keys
    @keyorder
  end

  def each(&blk)
    @keyorder.each { |k|
      blk.call(k, self[k])
    }
  end

  def first_key
    @keyorder.first
  end

  def first
    self[first_key]
  end

  def last_key
    @keyorder.last
  end

  def last
    self[last_key]
  end

  def clear
    super
    @keyorder.clear
  end

  def inspect
    str = "{"
    str << @keyorder.collect{|k| "#{k}=>#{self[k]}" }.join(', ')
    str << "}"
    str
  end

  def invert
    raise NotImplementedError
  end

end

