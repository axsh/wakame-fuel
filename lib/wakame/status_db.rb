

module Wakame
  module StatusDB
    
    def self.adapter
      @adapter ||= SequelAdapter.new
    end

    class SequelAdapter

      def initialize
        require 'sequel/core'
        require 'sequel/model'

        @db = Sequel.sqlite
        setup_store

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
          @enable_cache = true
          @_instance_cache = {}
        end

        def disable_cache
          @enable_cache = false
          @_instance_cache = {}
        end

        def _instance_cache
          return {} unless @enable_cache

          @_instance_cache ||= {}
        end

        def find(id)
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
          enable_cache
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

        hash_saved = self.dump_attrs
        StatusDB.adapter.save(self.id, hash_saved)
        @_orig = hash_saved.dup.freeze
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
