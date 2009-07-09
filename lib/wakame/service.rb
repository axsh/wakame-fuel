#!/usr/bin/ruby

require 'ostruct'

require 'wakame'
require 'wakame/util'

module Wakame
  module Service
    class ServiceError < StandardError; end
    class ServiceOk < StandardError; end
    class ServicePropagationError < ServiceError; end


    STATUS_OFFLINE = 0
    STATUS_ONLINE  = 1
    STATUS_UNKNOWN = 2
    STATUS_FAIL    = 3
    STATUS_STARTING = 4
    STATUS_STOPPING = 5
    STATUS_RELOADING = 6
    STATUS_MIGRATING = 7

    class Agent
      include ThreadImmutable
      include AttributeHelper
      STATUS_OFFLINE = 0
      STATUS_ONLINE  = 1
      STATUS_UNKNOWN = 2
      STATUS_TIMEOUT = 3
      
      attr_accessor :agent_id, :uptime, :last_ping_at, :attr, :services, :root_path, :lock_queue
      thread_immutable_methods :agent_id=, :uptime=, :last_ping_at=, :attr=, :services=, :root_path=

      def initialize(agent_id=nil)
        bind_thread
        @services = {}
        @agent_id = agent_id
        @last_ping_at = Time.now
        @status = STATUS_ONLINE
        @lock_queue = LockQueue.new(self)
      end

      def agent_ip
        attr[:local_ipv4]
      end

      def [](key)
        attr[key]
      end

      attr_reader :status

      def status=(status)
        if @status != status
          @status = status
          ED.fire_event(Event::AgentStatusChanged.new(self))
          # Send status specific event
          case status
          when STATUS_TIMEOUT
            ED.fire_event(Event::AgentTimedOut.new(self))
          end
        end
        @status
      end
      thread_immutable_methods :status=
      
      def has_service_type?(key)
        svc_class = case key
                    when Service::ServiceInstance
                      key.resource.class
                    when Service::Resource
                      key.class
                    when Class
                      key
                    else
                      raise ArgumentError
                    end

        services.any? { |k, v|
          Wakame.log.debug( "#{agent_id} of service #{v.resource.class}. v.resource.class == svc_class result to #{v.resource.class == svc_class}")
          
          v.property.class == svc_class
        }
      end


      def dump_status
        {:agent_id => @agent_id, :status => @status, :last_ping_at => @last_ping_at, :attr => attr.dup,
          :services => services.keys.dup
        }
      end
      
    end


    class ServiceCluster
      include ThreadImmutable

      attr_reader :dg, :instance_id, :status_changed_at, :rule_engine, :master
      attr_reader :status, :lock_queue

      STATUS_OFFLINE = 0
      STATUS_ONLINE = 1
      STATUS_PARTIAL_ONLINE = 2
      
      def initialize(master, &blk)
        bind_thread
        @master = master
        @instance_id =Wakame.gen_id
        @rule_engine ||= RuleEngine.new(self)
        @lock_queue = LockQueue.new(self)
        prepare
        
        instance_eval(&blk) if blk
      end

      def define_rule(&blk)
        @rule_engine ||= RuleEngine.new(self)
        
        blk.call(@rule_engine)
      end
      
      def add_resource(resource, name=nil)
        #if name.nil? || @name2prop.has_key? name
        #  name = "#{resource.class.to_s}#{name2prop.size + 1}"
        #end
        raise ArgumentError unless resource.is_a? Resource
        raise "Duplicate resource type registration" if @properties.has_key? resource.class.to_s
        @properties[resource.class.to_s]=resource
        @dg.add_object(resource.class.to_s)
        
        #name
      end
      thread_immutable_methods :add_resource
      
      def set_dependency(prop_name1, prop_name2)
        prop1 = @properties[prop_name1.to_s]
        prop2 = @properties[prop_name2.to_s]
        return unless prop1.is_a?(Property) && prop2.is_a?(Property) && prop1 != prop2
        @dg.set_dependency(prop_name1.to_s, prop_name2.to_s)
      end
      thread_immutable_methods :set_dependency

      def included_instance?(service_instance_id)
        @services.has_key? service_instance_id
      end


      def shutdown
      end
      thread_immutable_methods :shutdown

      # Create service instance objects which will be equivalent with the number min_instance.
      # The agents are not assigned at this point.
      def launch
        @properties.each { |n, p|
          count = instance_count(p)
          if p.min_instances > count
            (p.min_instances - count).times {
              propagate(p.class)
            }
          end
        }
      end
      thread_immutable_methods :launch

      def destroy(service_instance_id)
        raise("Unknown service instance : #{service_instance_id}") unless included_instance?(service_instance_id)
        svc_inst = @services[service_instance_id]
        old_agent = svc_inst.unbind_agent
        svc_inst.unbind_cluster
        @services.delete(service_instance_id)
        if old_agent
          Wakame.log.debug("#{svc_inst.property.class}(#{svc_inst.instance_id}) has been destroied from Agent #{old_agent.agent_id}")
        else
          Wakame.log.debug("#{svc_inst.property.class}(#{svc_inst.instance_id}) has been destroied.")
        end
      end
      thread_immutable_methods :destroy

      def propagate(property_name, force=false)
        property_name = case property_name
                        when Class, String
                          property_name.to_s
                        when Property
                          property_name.class.to_s
                        else
                          raise ArgumentError
                        end
        prop = @properties[property_name.to_s] || raise("Unknown property name: #{property_name.to_s}")
        if force == false
          instnum = instance_count(property_name)
          if instnum >= prop.max_instances
            Wakame.log.info("#{prop.class} has been reached max_instance limit: max=#{prop.max_instance}")
            raise ServicePropagationError, "#{prop.class} has been reached to max_instance limit" 
          end
        end
        
        svc_inst = Service::ServiceInstance.new(prop)
        svc_inst.bind_cluster(self)
        #svc_inst.bind_agent(agent) if agent

        @services[svc_inst.instance_id]=svc_inst
        svc_inst
      end
      thread_immutable_methods :propagate

      def instance_count(property_name=nil)
        return @services.size if property_name.nil?

        property_name = case property_name
                        when Class, String
                          property_name.to_s
                        when Property
                          property_name.class.to_s
                        else
                          raise ArgumentError
                        end

        raise "Unknown property name: #{property_name}" unless @properties.has_key?(property_name.to_s)
        c = 0
        each_instance(property_name) { |svc|
          c += 1
        }
        return c
      end

      def property_count
        @properties.size
      end

      def each_instance(filter_prop_name=nil, &blk)
        prop_obj = nil
        if filter_prop_name.is_a? String
          filter_prop_name = Util.build_const(filter_prop_name)
        end

        if filter_prop_name.is_a? Module
          prop_obj = @properties.find { |k, v|
            v.kind_of? filter_prop_name
          }
          if prop_obj.is_a? Array
            prop_obj = prop_obj[1]
          else
            raise("Unknown property name: #{filter_prop_name.to_s}")
          end
        end

        ary = []
        if prop_obj.nil?
          ary = @services.dup
        else
          ary = @services.find_all{|k, v| v.property.class == prop_obj.class }
          ary = Hash[*ary.flatten]
        end

        ary.each {|k,v| blk.call v } if block_given?
        ary
      end
      alias :select_instance :each_instance

      def status=(new_status)
        if @status != new_status
          @status = new_status
          @status_changed_at = Time.now
          ED.fire_event(Event::ClusterStatusChanged.new(instance_id, new_status))
        end
        @status
      end
      thread_immutable_methods :status=

      def size
        @dg.size
      end
      alias :num_services :size

      def properties
        @properties
      end

      def instances
        @services
      end


      def dump_status
        r = {:name => self.class.to_s, :status => self.status, :instances=>{}, :properties=>{} }
        
        instances.each { |k, i|
          r[:instances][k]=i.dump_status
        }
        properties.each { |k, i|
          r[:properties][k] = i.dump_status
          r[:properties][k][:instances] = each_instance(i.class).collect{|k, v| k }
        }

        r
      end
      thread_immutable_methods :dump_status
      
      private
      def prepare
        @dg = DependencyGraph.new(self)
        @services = {}
        
        @properties = {}
        @name2prop ={}
        @status = STATUS_OFFLINE
        @status_changed_at = Time.now
        @rule_engine = nil

        @status_check_timer = EM::PeriodicTimer.new(5) {
          update_cluster_status
        }

        @check_event_tickets = []
        [Event::ServiceOnline, Event::ServiceOffline, Event::ServiceFailed].each { |evclass|
          @check_event_tickets << ED.subscribe(evclass) { |event|
            update_cluster_status
          }
        }

#         ED.subscribe(Event::AgentTimedOut) { |event|
#           svc_in_timedout_agent = service_cluster.instances.select { |k, i|
#             if !i.agent.nil? && i.agent.agent_id == event.agent.agent_id
#               i.status = Service::STATUS_FAIL
#             end
#           }
          
#         }
      end
      thread_immutable_methods :prepare


      def update_cluster_status
        onlines = []
        all_offline = false
        onlines = self.instances.select { |k, i|
          i.status == Service::STATUS_ONLINE
        }
        all_offline = self.instances.all? { |k, i|
          i.status == Service::STATUS_OFFLINE
        }
        #Wakame.log.debug "online instances: #{onlines.size}, assigned instances: #{self.instances.size}"
        if self.instances.size == 0 || all_offline
          self.status = Service::ServiceCluster::STATUS_OFFLINE
        elsif onlines.size == self.instances.size
          self.status = Service::ServiceCluster::STATUS_ONLINE
        elsif onlines.size > 0
          self.status = Service::ServiceCluster::STATUS_PARTIAL_ONLINE
        end
        
      end
      thread_immutable_methods :update_cluster_status
      
    end

    class LockQueue
      def initialize(cluster)
        @service_cluster = cluster
        @locks = {}
        @id2res = {}

        @queue_by_thread = {}
        @qbt_m = ::Mutex.new
      end
      
      def set(resource, id)
        # Ths Job ID already holds/reserves the lock regarding the resource.
        return if @id2res.has_key?(id) && @id2res[id].has_key?(resource.to_s)

        EM.barrier {
          @locks[resource.to_s] ||= []
          @id2res[id] ||= {}
        
          @id2res[id][resource.to_s]=1
          @locks[resource.to_s] << id
        }
        Wakame.log.debug("#{self.class}: set(#{resource.to_s}, #{id})" + "\n#{self.inspect}")
      end

      def reset()
        @locks.keys { |k|
          @locks[k].clear
        }
        @id2res.clear
      end

      def test(id)
        reslist = @id2res[id]
        return :pass if reslist.nil? || reslist.empty?

        # 
        if reslist.keys.all? { |r| id == @locks[r.to_s][0] }
          return :runnable
        else
          return :wait
        end
      end

      def wait(id, tout=60*30)
        @qbt_m.synchronize { @queue_by_thread[Thread.current] = ::Queue.new }

        timeout(tout) {
          while test(id) == :wait
            Wakame.log.debug("#{self.class}: Job #{id} waits for locked resouces: #{@id2res[id].keys.join(', ')}")
            break if id == @queue_by_thread[Thread.current].deq
          end
        }
      ensure
        @qbt_m.synchronize { @queue_by_thread.delete(Thread.current) }
      end
      
      def quit(id)
        EM.barrier {
          case test(id)
          when :runnable, :wait
            @id2res[id].keys.each { |r| @locks[r.to_s].delete_if{ |i| i == id } }
            @qbt_m.synchronize {
              @queue_by_thread.each {|t, q| q.enq(id) }
            }
          end
          
          @id2res.delete(id)
        }
        Wakame.log.debug("#{self.class}: quit(#{id})" + "\n#{self.inspect}")
      end

      def clear_resource(resource)
      end

      def inspect
        output = @locks.collect { |k, lst|
          [k, lst].flatten
        }
        return "" if output.empty?

        # Table display
        maxcolws = (0..(output.size)).zip(*output).collect { |i| i.shift; i.map!{|i| (i.nil? ? "" : i).length }.max }
        maxcol = maxcolws.size
        maxcolws.reverse.each { |i| 
          break if i > 0
          maxcol -= 1
        }

        textrows = output.collect { |x|
          buf=""
          maxcol.times { |n|
            buf << "|" + (x[n] || "").ljust(maxcolws[n])
          }
          buf << "|"
        }

        "+" + (["-"] * (textrows[0].length - 2)).join('') + "+\n" + \
        textrows.join("\n") + \
        "\n+" + (["-"] * (textrows[0].length - 2)).join('')+ "+"
      end
    end
    
    
    class DependencyGraph
      
      def initialize(service_cluster)
        @graph = Graph.new
        @graph.add_vertex(0)
        @service_cluster = service_cluster
        @nodes = {}
      end
      
      
      def add_object(obj)
        @nodes[obj.hash] = obj
        @graph.add_edge(0, obj.hash)
        self
      end
      
      def set_dependency(parent_obj, child_obj)
        return if parent_obj == child_obj
        @graph.add_edge(parent_obj.hash, child_obj.hash)
        @graph.remove_edge(0, child_obj.hash) if @graph.has_edge?(0, child_obj.hash)
        self
      end
      
      def size
        @graph.size - 1
      end

      def parents(obj)
        obj = case obj
               when Class
                 obj.to_s.hash
               when String
                 obj.hash
               else
                 raise ArgumentError
               end
        @graph.parents(obj).collect { |hashid| property_obj(hashid) }
      end

      def children(obj)
        obj = case obj
               when Class
                 obj.to_s.hash
               when String
                 obj.hash
               else
                 raise ArgumentError
               end
        @graph.children(obj).collect { |hashid| property_obj(hashid) }
      end
      
      def levels(root=nil)
        root = case root
               when nil
                 0
               when Class
                 root.to_s.hash
               when String
                 root.hash
               else
                 raise ArgumentError
               end
        n=[]
        @graph.level_layout(root).each { |l|
          next if l.size == 1 && l[0] == 0
          n << l.collect { |hashid| property_obj(hashid)}
          #n << l.collect { |hashid| @nodes[hashid].to_s }
        }
        n
      end
      
      def each_level(root=nil, &blk)
        root = case root
               when nil
                 0
               when Class
                 root.to_s.hash
               when String
                 root.hash
               else
                 raise ArgumentError
               end
        @graph.level_layout(root).each { |l|
          l.each { |hashid|
            next if hashid == 0
            blk.call(@service_cluster.properties[@nodes[hashid]])
          }
        }
      end
      
      private
      def property_obj(hashid)
        @service_cluster.properties[@nodes[hashid]]
      end
    end
    
    
    class ServiceInstance
      include ThreadImmutable
      attr_reader :instance_id, :service_property, :agent, :service_cluster, :status_changed_at
      attr_accessor :name
      alias :cluster :service_cluster
      alias :property :service_property
      
      class << self
        def instance_collection
          @collection ||= {}
        end
      end
      
      def initialize(service_property)
        bind_thread
        raise TypeError unless service_property.is_a?(Property)
        
        @instance_id = Wakame.gen_id
        @service_property = service_property
        @status = Service::STATUS_OFFLINE
        @status_changed_at = Time.now

        self.class.instance_collection[@instance_id] = self
      end
      
      def update_status(new_status, changed_at=Time.now, fail_message=nil)
        if @status != new_status
          prev_status = @status
          @status = new_status
          @status_changed_at = changed_at
          
          event = Event::ServiceStatusChanged.new(@instance_id, @service_property, new_status, prev_status)
          event.time = @status_changed_at.dup
          ED.fire_event(event)

          tmp_event = nil
          if prev_status != Service::STATUS_ONLINE && new_status == Service::STATUS_ONLINE
            tmp_event = Event::ServiceOnline.new(self.instance_id, self.property)
            tmp_event.time = @status_changed_at.dup
          elsif prev_status != Service::STATUS_OFFLINE && new_status == Service::STATUS_OFFLINE
            tmp_event = Event::ServiceOffline.new(self.instance_id, self.property)
            tmp_event.time = @status_changed_at.dup
          elsif prev_status != Service::STATUS_FAIL && new_status == Service::STATUS_FAIL
            tmp_event = Event::ServiceFailed.new(self.instance_id, self.property, fail_message)
            tmp_event.time = @status_changed_at.dup
          end
          ED.fire_event(tmp_event) if tmp_event

        end
        @status
      end
      thread_immutable_methods :update_status
      

      def status
        @status
      end
      
      def property
        @service_property
      end
      def resource
        @service_property
      end
      
      def type
        @service_property.class
      end
      
      def bind_agent(agent)
        return if agent.nil? || (@agent && agent.agent_id == @agent.agent_id)
        raise "The agent (#{agent.agent_id}) was assigned same service already: #{property.class}" if agent.has_service_type?(property.class)
        
        # UboundAgent & BoundAgent event occured only when the different agent obejct is assigned.
        unbind_agent
        @agent = agent
        @agent.services[instance_id]=self
        
        ED.fire_event(Event::ServiceBoundAgent.new(self, agent))
        @agent
      end
      thread_immutable_methods :bind_agent
      
      def unbind_agent
        return nil if @agent.nil?
        @agent.services.delete(instance_id)
        old_item = @agent
        @agent = nil
        ED.fire_event(Event::ServiceUnboundAgent.new(self, old_item))
        old_item
      end
      thread_immutable_methods :unbind_agent

      def bind_cluster(cluster)
        return if cluster.nil? || (@service_cluster && cluster.instance_id == @service_cluster.instance_id)
        unbind_cluster
        @service_cluster = cluster
        ED.fire_event(Event::ServiceBoundCluster.new(self, cluster))
      end
      thread_immutable_methods :bind_cluster

      def unbind_cluster
        return if @service_cluster.nil?
        old_item = @service_cluster
        @service_cluster = nil
        ED.fire_event(Event::ServiceUnboundCluster.new(self, old_item))
      end
      thread_immutable_methods :unbind_cluster
      
      def export_binding
        binding
      end
      
      def dump_status
        ret = {:type => self.class.to_s, :status => status, :property => property.class.to_s, :instance_id => instance_id}
        ret[:agent_id] = agent.agent_id if agent
        ret
      end
      thread_immutable_methods :dump_status

      def parent_instances
        ary = []
        @service_cluster.dg.parents(resource.class).each { |r|
          @service_cluster.each_instance(r.class){ |i|
            ary << i
          }
        }
        ary.flatten
      end
      
      def child_instances
        ary = []
        @service_cluster.dg.children(resource.class).each { |r|
          @service_cluster.each_instance(r.class){ |i|
            ary << i
          }
        }
        ary.flatten
      end
    end


    class VmSpec
      def self.define(&blk)
        spec = self.new
        spec.instance_eval(&blk)
        spec
      end

      def initialize
        @environments = {}
      end

      def current
        environment(Wakame.config.environment)
      end

      def environment(klass_key, &blk)
        envobj = @environments[klass_key]
        if envobj.nil?
          #klass = self.class.constants.find{ |c| c.to_s == klass_key.to_s }
          if self.class.const_defined?(klass_key)
            envobj = @environments[klass_key] = Wakame.new_([self.class.to_s, klass_key.to_s].join('::'))
          else
            raise "Undefined VM Spec template : #{klass_key}"
          end
        end

        envobj.instance_eval(&blk) if blk

        envobj
      end

      class Template
        def self.inherited(klass)
          klass.class_eval {
            def self.default_attr_values
              @default_attr_values ||= {}
            end
            def self.def_attribute(name, default_value=nil)
              default_attr_values[name.to_sym]= default_value
              attr_accessor(name)
            end
          }
        end
        
        def initialize
          @attribute_keys=[]
          self.class.default_attr_values.each { |n, v|
            instance_variable_set("@#{n.to_s}", v)
            #self.instance_eval %Q{ #{n} = #{v} }
            @attribute_keys << n
          }
        end

        def attrs
          a={}
          @attribute_keys.each { |k|
            a[k.to_sym]=instance_variable_get("@#{k.to_s}")
          }
          a
        end

        def satisfy?(agent)
          true
        end
      end

      class EC2 < Template
        AWS_VERSION=''
        def_attribute :instance_type, 'm1.small'
        def_attribute :availability_zone
        def_attribute :key_name
        def_attribute :security_groups, []
      end

      class StandAlone < Template
      end
    end


    class Property
      include AttributeHelper
      attr_accessor :check_time, :vm_spec
      def_attribute :duplicable, true
      def_attribute :min_instances, 1
      def_attribute :max_instances, 1
      def_attribute :startup, true
      def_attribute :require_agent, true

      def initialize(check_time=5)
        @check_time = check_time
        @vm_spec = VmSpec.define {
          environment(:EC2) { |ec2|
            ec2.instance_type = 'm1.small'
            ec2.availability_zone = 'us-east-1c'
            ec2.security_groups = ['default']
          }
          
          environment(:StandAlone) {
          }
        }
      end

      def basedir
        File.join(Wakame.config.root_path, 'cluster', 'resources', Util.snake_case(self.class))
      end

      def dump_status
        {:type => self.class.to_s, :min_instances => min_instances, :max_instances=> max_instances,
          :duplicable=>duplicable
        }
      end

      def start(service_instance, action); end
      def stop(service_instance, action); end
      def reload(service_instance, action); end

      def render_config(template)
      end

      #def before_start(service_instance, action)
      #end
      #def after_start(service_instance, action)
      #end
      #def before_stop(service_instance, action)
      #end
      #def after_stop(service_instance, action)
      #end

      def on_child_changed(service_instance, action)
      end
      def on_parent_changed(service_instance, action)
      end

    end

    Resource = Property
  end
end

module Wakame
  module Service


    module ApacheBasicProps
      attr_accessor :listen_port, :listen_port_https, :server_root
      
    end

    class MySQL_Slave < Property
      attr_reader :basedir, :mysqld_datadir, :mysqld_port, :mysqld_server_id, :mysqld_log_bin, :ebs_volume, :ebs_device

      def initialize
        super()
        @template = ConfigurationTemplate::MySQLSlaveTemplate.new()
        @basedir = '/home/wakame/mysql'

        @mysqld_server_id = 2 # dynamic
        @mysqld_port = 3307
        @mysqld_datadir = File.expand_path('data-slave', @basedir)

        @ebs_volume = 'vol-38bc5f51'  # master volume_id
        @ebs_device = '/dev/sdn'      # slave mount point
        @ebs_mount_option = 'noatime'

        @mysqld_master_host = '10.249.2.115'
        @mysqld_master_user = 'wakame-repl'
        @mysqld_master_pass = 'wakame-slave'
        @mysqld_master_port = 3306
        @mysqld_master_datadir = File.expand_path('data', @basedir)

        @duplicable = false
      end

      def before_start(svc, action)
        vm_manipulator = VmManipulator.create

        Wakame.log.debug("mkdir #{@mysqld_datadir}")
        system("[ -d #{@mysqld_datadir} ] || mkdir -p #{@mysqld_datadir}")
        Wakame.log.debug("[ -b #{@ebs_device} ]")
        system("[ -b #{@ebs_device} ]")
        if $? == 0
          Wakame.log.debug("The EBS volume(slave) device is not ready to attach: #{@ebs_device}")
          return
        end

        volume_map = vm_manipulator.describe_volume(@ebs_volume)
        Wakame.log.debug("describe_volume(#{@ebs_volume}): #{volume_map.inspect}")
        if volume_map['status'] == 'in-use'
          # Nothin to be done
        else
          Wakame.log.debug("The EBS volume(slave) is not ready to attach: #{@ebs_volume}")
          return
        end

        system("echo show master status | /usr/bin/mysql -h#{@mysqld_master_host} -P#{@mysqld_master_port} -u#{@mysqld_master_user}  -p#{@mysqld_master_pass}")
        if $? != 0
          raise "Can't connect mysql master: #{@mysqld_master_host}:#{@mysqld_master_port}"
        end

        system("echo 'FLUSH TABLES WITH READ LOCK;' | /usr/bin/mysql -h#{@mysqld_master_host} -P#{@mysqld_master_port} -u#{@mysqld_master_user}  -p#{@mysqld_master_pass} -s")
        master_status = `echo show master status | /usr/bin/mysql -h#{@mysqld_master_host} -P#{@mysqld_master_port} -u#{@mysqld_master_user}  -p#{@mysqld_master_pass} -s`.to_s.split(/\t/)[0..1]
#        p master_status

        # mysql/data/master.info
        master_infos = []
        master_infos << 14
        master_infos << master_status[0]
        master_infos << master_status[1]
        master_infos << @mysqld_master_host
        master_infos << @mysqld_master_user
        master_infos << @mysqld_master_pass
        master_infos << @mysqld_master_port
        master_infos << 60
        master_infos << 0
        master_infos << ""
        master_infos << ""
        master_infos << ""
        master_infos << ""
        master_infos << ""
        master_infos << ""

        tmp_output_basedir = File.expand_path(Wakame.gen_id, "/tmp")
        FileUtils.mkdir_p tmp_output_basedir
        master_info = File.expand_path('master.info', tmp_output_basedir)
        file = File.new(master_info, "w")
        file.puts(master_infos.join("\n"))
        file.chmod(0664)
        file.close

        3.times do |i|
          system("/bin/sync")
          sleep 1.0
        end

        Wakame.log.debug("scp -i #{Wakame.config.ssh_private_key} -o \"UserKnownHostsFile #{Wakame.config.ssh_known_hosts}\" #{master_info} root@#{@mysqld_master_host}:#{@mysqld_master_datadir}/" )
        system("scp -i #{Wakame.config.ssh_private_key} -o \"UserKnownHostsFile #{Wakame.config.ssh_known_hosts}\" #{master_info} root@#{@mysqld_master_host}:#{@mysqld_master_datadir}/" )
        Wakame.log.debug("ssh -i #{Wakame.config.ssh_private_key} -o \"UserKnownHostsFile #{Wakame.config.ssh_known_hosts}\" root@#{@mysqld_master_host} chown mysql:mysql #{@mysqld_master_datadir}/master.info" )
        system("ssh -i #{Wakame.config.ssh_private_key} -o \"UserKnownHostsFile #{Wakame.config.ssh_known_hosts}\" root@#{@mysqld_master_host} chown mysql:mysql #{@mysqld_master_datadir}/master.info" )

        3.times do |i|
          system("/bin/sync")
          sleep 1.0
        end

        FileUtils.rm_rf tmp_output_basedir

        # 2. snapshot
        Wakame.log.debug("create_snapshot (#{@ebs_volume})")
        snapshot_map = vm_manipulator.create_snapshot(@ebs_volume)
        16.times do |i|
          Wakame.log.debug("describe_snapshot(#{snapshot_map.snapshotId}) ... #{i}")
          snapshot_map = vm_manipulator.describe_snapshot(snapshot_map["snapshotId"])
          if snapshot_map["status"] == "completed"
            break
          end
          sleep 1.0
        end
        if snapshot_map["status"] != "completed"
          raise "#{snapshot_map.snapshotId} status is #{snapshot_map.status}"
        end

        # 3. unlock mysql-master
        system("echo 'UNLOCK TABLES;' | /usr/bin/mysql -h#{@mysqld_master_host} -P#{@mysqld_master_port} -u#{@mysqld_master_user}  -p#{@mysqld_master_pass}")

        # create volume /dev/xxxx
        Wakame.log.debug("create_volume_from_snapshot(#{volume_map.availabilityZone}, #{snapshot_map.snapshotId})")
        created_volume_from_snapshot_map = vm_manipulator.create_volume_from_snapshot(volume_map["availabilityZone"], snapshot_map["snapshotId"])
        volume_from_snapshot_map = created_volume_from_snapshot_map
        16.times do |i|
          Wakame.log.debug("describe_snapshot(#{snapshot_map.snapshotId}) ... #{i}")
          volume_from_snapshot_map = vm_manipulator.describe_snapshot(snapshot_map["snapshotId"])
          if volume_from_snapshot_map["status"] == "completed"
            break
          end
          sleep 1.0
        end
        if volume_from_snapshot_map["status"] != "completed"
          raise "#{volume_from_snapshot_map.snapshotId} status is #{volume_from_snapshot_map.status}"
        end

        # attach volume
        attach_volume_map = vm_manipulator.attach_volume(svc.agent.agent_id, created_volume_from_snapshot_map["volumeId"], @ebs_device)
        16.times do |i|
          Wakame.log.debug("describe_volume(#{attach_volume_map.volumeId}) ... #{i}")
          attach_volume_map = vm_manipulator.describe_volume(created_volume_from_snapshot_map["volumeId"])
          if attach_volume_map["status"] == "in-use"
            break
          end
          sleep 1.0
        end
        if attach_volume_map["status"] != "in-use"
          raise "#{attach_volume_map.volumeId} status is #{attach_volume_map.status}"
        end
      end
        
      def start
        mount_point_dev=`df "#{@mysqld_datadir}" | awk 'NR==2 {print $1}'`
        if mount_point_dev != @ebs_device
          Wakame.log.debug("Mounting EBS volume: #{@ebs_device} as #{@mysqld_datadir} (with option: #{@ebs_mount_option})")
          system("/bin/mount -o #{@ebs_mount_option} #{@ebs_device} #{@mysqld_datadir}")
        end
        system(Wakame.config.root + "/config/init.d/mysql-slave start")
      end
      
      def check
        system("/usr/bin/mysqladmin --defaults-file=/home/wakame/config/mysql-slave/my-slave.cnf ping > /dev/null")
        return false if $? != 0
        true
      end
      
      def stop
        system(Wakame.config.root + "/config/init.d/mysql-slave stop")
      end
    end
    
  end
end
