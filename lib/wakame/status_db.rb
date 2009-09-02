
require 'thread'
require 'wakame/master'

module Wakame
  module StatusDB

    def self.pass(&blk)
      if Thread.current == WorkerThread.worker_thread
        blk.call
      else
        WorkerThread.queue.enq(blk)
      end
    end
    
    def self.barrier(&blk)
      abort "Cant use barrier() in side of the EventMachine thread." if Kernel.const_defined?(:EventMachine) && ::EventMachine.reactor_thread?

      if Thread.current == WorkerThread.worker_thread
        return blk.call
      end
      
      @q ||= ::Queue.new
      time_start = ::Time.now
      
      self.pass {
        begin
          res = blk.call
          @q << [true, res]
        rescue => e
          @q << [false, e]
        end
      }
      
      res = @q.shift
      time_elapsed = ::Time.now - time_start
      Wakame.log.debug("#{self}.barrier: Elapsed time for #{blk}: #{time_elapsed} sec") if time_elapsed > 0.05
      if res[0] == false && res[1].is_a?(Exception)
        raise res[1]
      end
      res[1]
    end
    
    class WorkerThread

      def self.queue
        @queue ||= ::Queue.new
      end

      def self.worker_thread
        @thread 
      end

      def self.init
        @proceed_reqs = 0

        if @thread.nil?
          @thread = Thread.new {
            while blk = queue.deq
              begin
                blk.call
              rescue => e
                Wakame.log.error("#{self.class}: #{e}")
                Wakame.log.error(e)
              end
              @proceed_reqs += 1
            end
          }
        end
      end

      def self.terminate
        if self.queue.size > 0
          Wakame.log.warn("#{self.class}: #{self.class.queue.size} of non-processed reqs are going to be ignored to shutdown the worker thread.")
          self.queue.clear
        end
        self.worker_thread.kill if !self.worker_thread.nil? && self.worker_thread.alive?
      end
    end


    def self.adapter
      @adapter ||= SequelAdapter.new
    end

    class SequelAdapter
      DATA_FORMAT_VERSION='0.4'

      def initialize
        require 'sequel/core'
        require 'sequel/model'

        @db = Sequel.connect(Wakame.config.status_db_dsn, {:logger=>Wakame.log})
        
        if [:metadata, :model_stores].all?{ |i| @db.table_exists?(i) }
          m = @db[:metadata].where(:id=>1).first

          unless m && m[:version] == DATA_FORMAT_VERSION
            setup_store
          end

        else
          setup_store
        end

        # Generate Sequel::Model class dynamically.
        # This is same as below:
        # class ModelStore < Sequel::Model
        #    unrestrict_primary_key
        # end
        @model_class = Class.new(Sequel::Model(:model_stores)) { |klass|
          klass.unrestrict_primary_key
        }
      end

      def setup_store
        @db.drop_table :metadata rescue nil
        @db.create_table? :metadata do
          primary_key :id
          column :version, :string
          column :created_at, :datetime
        end

        @db[:metadata].insert(:version=>DATA_FORMAT_VERSION, :created_at=>Time.now)

        @db.drop_table :model_stores rescue nil
        @db.create_table? :model_stores do
          primary_key :id, :string, :size=>50, :auto_increment=>false
          column :class_type, :string
          column :dump, :text
          column :created_at, :datetime
          column :updated_at, :datetime
        end
      end

      def find(id, &blk)
        m = @model_class[id]
        if m
          hash = eval(m[:dump])
          blk.call(id, hash)
        end
      end

      # Find all rows belong to given klass name.
      # Returns id list which matches class_type == klass
      def find_all(klass)
        ds = @model_class.where(:class_type=>klass.to_s)
        ds.all.map {|r| r[:id] }
      end

      def exists?(id)
        !@model_class[id].nil?
      end

      def save(id, hash)
        m = @model_class[id]
        if m.nil? 
          m = @model_class.new
          m.id = id
          m.class_type = hash[AttributeHelper::CLASS_TYPE_KEY]
       end 
        m.dump = hash.inspect
        m.save
      end

      def delete(id)
        @model_class[id].destroy
      end

      def clear_store
        setup_store
      end
      
    end


    class Model
     include ::AttributeHelper

      module ClassMethods
        def enable_cache
          unless @enable_cache
            @enable_cache = true
            @_instance_cache = {}
          end
        end

        def disable_cache
          if @enable_cache
            @enable_cache = false
            @_instance_cache = {}
          end
        end

        def _instance_cache
          return {} unless @enable_cache

          @_instance_cache ||= {}
        end

        def find(id)
          raise "Can not retrieve the data with nil." if id.nil?
          obj = _instance_cache[id]
          return obj unless obj.nil?

          StatusDB.adapter.find(id) { |id, hash|
            if hash[AttributeHelper::CLASS_TYPE_KEY]
              klass_const = Util.build_const(hash[AttributeHelper::CLASS_TYPE_KEY])
            else
              klass_const = self.class
            end

            # klass_const class is equal to self class or child of self class
            if klass_const <= self
              obj = klass_const.new
            else
              raise "Can not instanciate the object #{klass_const.to_s} from #{self}"
            end

            obj.on_before_load

            obj.instance_variable_set(:@id, id)
            obj.instance_variable_set(:@_orig, hash.dup.freeze)
            obj.instance_variable_set(:@load_at, Time.now)
        
            hash.each { |k,v|
              obj.instance_variable_set("@#{k}", v)
            }

            obj.on_after_load
          }

          _instance_cache[id] = obj
          obj
        end


        def find_all
          StatusDB.adapter.find_all(self.to_s).map { |id|
            find(id)
          }
        end

        def exists?(id) 
          _instance_cache.has_key?(id) || StatusDB.adapter.exists?(id)
        end

        # A helper method to define an accessor with persistent flag.
        def property(key, opts={})
          case opts 
          when Hash
            opts.merge!({:persistent=>true})
          else
            opts = {:persistent=>true}
          end
          def_attribute(key.to_sym, opts)
        end

        def delete(id)
          StatusDB.adapter.delete(self.id)
          _instance_cache.delete(id)
        end

      end

      def self.inherited(klass)
        klass.extend(ClassMethods)
        klass.class_eval {
          #include(::AttributeHelper)
          #enable_cache

          # Manually set attr option to get :id appeared in dump_attrs.
          attr_attributes[:id]={:persistent=>false}
        }
      end

      def id
        @id ||= Wakame::Util.gen_id
      end

      def new_record?
        @load_at.nil?
      end

      def dirty?(key=nil)
        return true if new_record?

        if key
          attr_attr = self.class.get_attr_attribute(key.to_sym)
          raise "#{key} is not the key to be saved" if attr_attr.nil? || !attr_attr[:persistent]
          return @_orig[key.to_sym] != self.__send__(key.to_sym)
        else
          self.class.merged_attr_attributes.each { |k,v|
            next unless v[:persistent]
            #p "@_orig[#{k.to_sym}]=#{@_orig[k.to_sym].inspect}"
            #p "@self.__send__(#{k.to_sym})=#{self.__send__(k.to_sym).inspect}"
            return true if @_orig[k.to_sym] != self.__send__(k.to_sym)
          }
          return false
        end
      end

      def save
#        return unless dirty?
#       raise "No change" unless dirty?

        validate_on_save

        self.class.merged_attr_attributes.each { |k,v|
          next unless v[:persistent]
          if dirty?(k) && v[:call_after_changed]
            case v[:call_after_changed]
            when Symbol
              self.__send__(v[:call_after_changed].to_sym) # if self.respond_to?(v[:call_after_changed].to_sym)
            when Proc
              v[:call_after_changed].call(self)
            end
          end
        }

        hash_saved = self.dump_attrs { |k,v,dumper|
          if v[:persistent] == true
            dumper.call(k)
          end
        }
        @_orig = hash_saved.dup.freeze

        StatusDB.adapter.save(self.id, hash_saved)
      end

      def delete
        self.class.delete(self.id)
      end

      def reload
        self.class._instance_cache.delete(self.id)
        self.class.find(self.id)
      end

      # Callback methods
      
      # Called prior to copying data from database in self.find().
      def on_before_load
      end
      # Called after copying data from database in self.find().
      def on_after_load
      end

      protected

      def validate_on_save
      end


    end
    
  end
  
end
