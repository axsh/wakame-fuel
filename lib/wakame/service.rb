#!/usr/bin/ruby

require 'ostruct'

require 'wakame'
require 'wakame/configuration_template'
require 'wakame/util'

module Wakame
  module Service
    class ServiceError < StandardError; end
    class ServiceOk < StandardError; end
    class ServicePropagationError < ServiceError; end


    STATUS_OFFLINE = STATUS_DOWN = 0
    STATUS_ONLINE = STATUS_UP = STATUS_RUN = 1
    STATUS_UNKNOWN = 2
    STATUS_FAIL = 3
    STATUS_STARTING = 4
    STATUS_STOPPING = 5
    STATUS_RELOADING = 6
    STATUS_MIGRATING = 7

    class Agent
      include ThreadImmutable
      include AttributeHelper
      STATUS_DOWN = STATUS_OFFLINE =0
      STATUS_UP = STATUS_ONLINE =1
      STATUS_UNKNOWN=2
      STATUS_TIMEOUT=3
      
      attr_accessor :agent_id, :uptime, :last_ping_at, :attr, :services
      thread_immutable_methods :agent_id=, :uptime=, :last_ping_at=, :attr=, :services=

      def initialize(agent_id=nil)
        bind_thread
        @services = {}
        @agent_id = agent_id
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
                      key.property.class
                    when Class
                      key
                    else
                      nil
                    end

        services.any? { |k, v|
          v.property.class == svc_class
        }
      end


      #def dump_status
      #  {:agent_id => @agent_id, :status => @status, :last_ping_at => @last_ping_at, :attr => attr.dup,
      #    :services => services.keys.dup
      #  }
      #end
      
    end


    class ServiceCluster
      class << self
        
        def instance_collection
          @collection ||= {}
        end
      end

      include ThreadImmutable

      attr_reader :dg, :instance_id, :status_changed_at, :rule_engine, :master
      attr_reader :status

      STATUS_OFFLINE = 0
      STATUS_ONLINE = 1
      STATUS_PARTIAL_ONLINE = 2
      
      def initialize(master, &blk)
        bind_thread
        @master = master
        @instance_id =Wakame.gen_id
        prepare
        
        instance_eval(&blk) if blk
        
        self.class.instance_collection[@instance_id] = self
      end
      
      def add_service(service_property, name=nil)
        #if name.nil? || @name2prop.has_key? name
        #  name = "#{service_property.class.to_s}#{name2prop.size + 1}"
        #end
        raise "Duplicate service property registration" if @properties.has_key? service_property.class.to_s
        @properties[service_property.class.to_s]=service_property
        @dg.add_object(service_property.class.to_s)
        
        #name
      end
      thread_immutable_methods :add_service
      
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
          count = 0
          each_instance(p.class) { |svc|
            count += 1
          }
          
          if p.instance_count > count
            (p.instance_count - count).times {
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
          filter_prop_name = Wakame.str2const(filter_prop_name)
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
      end
      thread_immutable_methods :prepare
      
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
      attr_accessor :name, :status
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
      
      def status=(new_status)
        if @status != new_status
          prev_status = @status
          set_status(new_status, Time.now)
          
          event = Event::ServiceStatusChanged.new(@instance_id, @service_property, @status, prev_status)
          event.time = @status_changed_at.dup
          ED.fire_event(event)
        end
        @status
      end
      thread_immutable_methods :status=
      
      def set_status(new_status, changed_at)
        @status = new_status
        @status_changed_at = changed_at
      end
      thread_immutable_methods :set_status
      
      def property
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
        environment(Wakame.config.vm_environment)
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

    class InstanceCounter
      class OutOfLimitRangeError < StandardError; end

      include AttributeHelper
      
      def bind_resource(resource)
        @resource = resource
      end

      def resource
        @resource
      end

      def instance_count
        raise NotImplementedError
      end

      protected
      def check_hard_limit(count=self.instance_count)
        Range.new(@resource.min_instances, @resource.max_instances, true).include?(count)
      end
    end


    class ConstantCounter < InstanceCounter
      def initialize(resource)
        @instance_count = 1
        bind_resource(resource)
      end

      def instance_count
        @instance_count
      end

      def instance_count=(count)
        raise OutOfLimitRangeError unless check_hard_limit(count)
        if @instance_count != count
          prev = @instance_count
          @instance_count = count
          ED.fire_event(Event::InstanceCountChanged.new(@resource, prev, count))
        end
      end
    end

    class TimedCounter < InstanceCounter
      def initialize(seq, resource)
        @sequence = seq
        bind_resource(resource)
        timer = Scheduler::SequenceTimer.new(seq)
        timer.add_observer(self)
        @instance_count = 1
      end

      def instance_count
        @instance_count
      end

      def update(*args)
        new_count = args[0]
        if @instance_count != count
          prev = @instance_count
          @instance_count = count
          ED.fire_event(Event::InstanceCountChanged.new(@resource, prev, count))
        end
        #if self.min > new_count || self.max < new_count
        #if self.min != new_count || self.max != new_count
        #  prev_min = self.min
        #  prev_max = self.max

        #  self.max = self.min = new_count
        #  ED.fire_event(Event::InstanceCountChanged.new(@resource, prev_min, prev_max, self.min, self.max))
        #end

      end
    end

    class Property
      include AttributeHelper
      attr_accessor :check_time, :vm_spec
      attr_accessor :template, :instance_counter
      def_attribute :duplicable, true
      def_attribute :min_instances, 1
      def_attribute :max_instances, 1
      def_attribute :startup, true
      def_attribute :instance_counter, proc{ |my| ConstantCounter.new(my) }

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

      def instance_count
        instance_counter.instance_count
      end

      def dump_status
        {:type => self.class.to_s, :min_instances => min_instances, :max_instances=> max_instances,
          :duplicable=>duplicable, :instance_count => instance_count,
          :instance_counter_class => instance_counter.class.to_s
        }
      end

      def start; end
      def check; end
      def stop; end
      def reload; end

      def before_start(service_instance, action)
      end
      def after_start(service_instance, action)
      end
      def before_stop(service_instance, action)
      end
      def after_stop(service_instance, action)
      end

      def on_child_changed(action, svc_inst)
      end
      def on_parent_changed(action, svc_inst)
      end

    end

    Resource = Property
  end
end

module Wakame
  module Service
    class WebCluster < ServiceCluster
      attr_accessor :propagation_priority
      
      module HttpAppServer; end
      module HttpAssetServer; end
      module HttpLoadBalanceServer; end

      VirtualHost = Class.new(OpenStruct)

      class RuleSet < Rule::RuleEngine
        def initialize(sc)
          super(sc) {
            register_rule(Rule::ProcessCommand.new)
            register_rule(Rule::MaintainSshKnownHosts.new)
            register_rule(Rule::ClusterStatusMonitor.new)
            register_rule(Rule::LoadHistoryMonitor.new)
            register_rule(Rule::InstanceCountUpdate.new)
            #register_rule(Rule::ReflectPropagation_LB_Subs.new)
            #register_rule(Rule::ScaleOutWhenHighLoad.new)
            #register_rule(Rule::ShutdownUnusedVM.new)
          }

        end
      end


      def initialize(master, &blk)
        super(master) {
          add_service(Apache_WWW.new)
          add_service(Apache_APP.new)
          add_service(Apache_LB.new)
          add_service(MySQL_Master.new)
#          add_service(MySQL_Slave.new)

          set_dependency(Apache_WWW, Apache_LB)
          set_dependency(Apache_APP, Apache_LB)
          set_dependency(MySQL_Master, Apache_APP)
#          set_dependency(MySQL_Master, MySQL_Slave)

          @rule_engine = RuleSet.new(self)
        }

        add_virtual_host(VirtualHost.new(:server_name=>'aaa.test', :document_root=>'/home/wakame/app/development/test/public'))
        add_virtual_host(VirtualHost.new(:server_name=>'bbb.test', :document_root=>'/home/wakame/app/development/test/public'))

        @propagation_priority = [Apache_APP, Apache_WWW]
      end

      def virtual_hosts
        @virtual_hosts ||= []
      end

      def add_virtual_host(vh)
        virtual_hosts << vh
      end


      def each_app(&blk)
        each_instance(HttpAppServer) { |n|
          blk.call(n)
        }
      end

      def each_www(&blk)
        each_instance(HttpAssetServer) { |n|
          blk.call(n)
        }
      end

      def each_mysql(&blk)
        each_instance(MySQL_Master) { |n|
          blk.call(n)
        }
      end

    end


    

    module ApacheBasicProps
      attr_accessor :listen_port, :listen_port_https
      
    end
    

    class Apache_WWW < Property
      include ApacheBasicProps
      include WebCluster::HttpAssetServer

      def initialize
        super()
        @listen_port = 8000
        @template = ConfigurationTemplate::ApacheTemplate.new(:www)
        @max_instances = 5
      end
      
      def start
        system(Wakame.config.root + '/config/init.d/apache2-www start')
      end
      
      def check
        system("for i in `pidof apache2`; do ps -f $i; done | egrep -e '-DWWW' >/dev/null")
        return false if $?.to_i != 0
        true
      end
      
      def stop
        system(Wakame.config.root + '/config/init.d/apache2-www stop')
      end

      def reload
        system(Wakame.config.root +  '/config/init.d/apache2-www reload')
      end

    end
    
    class Apache_APP < Property
      include ApacheBasicProps
      include WebCluster::HttpAppServer

      def initialize
        super()
        @listen_port = 8001
        @max_instances = 5
        ms = Scheduler::PerHourSequence.new
        #ms[0]=1
        #ms[30]=5
        ms[0]=1
        ms["0:2:00"]=4
        ms["0:5:00"]=1
        ms["0:9:00"]=4
        ms["0:13:00"]=1
        ms["0:17:00"]=4
        ms["0:21:00"]=1
        ms["0:25:00"]=1
        ms["0:29:00"]=1
        ms["0:33:00"]=4
        #ms["0:37:00"]=1
        #ms["0:41:00"]=4
        ms["0:45:00"]=1
        ms["0:49:00"]=4
        ms["0:53:00"]=1
        ms["0:57:00"]=4
        # @instance_counter = TimedCounter.new(Scheduler::LoopSequence.new(ms), self)

        @template = ConfigurationTemplate::ApacheTemplate.new(:app)
      end

      def start
        #Wakame.shell.transact {
        #  system("pwd")
          system(Wakame.config.root + '/config/init.d/apache2-app start')
        #}
      end
      
      def check
        system("for i in `pidof apache2`; do ps -f $i; done | egrep -e '-DAPP' >/dev/null")
        return false if $?.to_i != 0
        true
      end

      def stop
        system(Wakame.config.root + "/config/init.d/apache2-app stop")
      end

      def reload
        system(Wakame.config.root +  '/config/init.d/apache2-app reload')
      end

    end

    class Apache_LB < Property
      include WebCluster::HttpLoadBalanceServer
      include ApacheBasicProps

      attr_reader :elastic_ip

      def initialize
        super()
        @listen_port = 80
        @listen_port_https = 443
        @template = ConfigurationTemplate::ApacheTemplate.new(:lb)
        @elastic_ip = ''
      end

      def on_parent_changed(action, svc_inst)
        action.deploy_configuration(svc_inst)
        action.trigger_action(Rule::ReloadService.new(svc_inst))
      end

      def after_start(svc, action)
        vm_manipulator = VmManipulator.create
        Wakame.log.info("Associating the Elastic IP #{@elastic_ip} to #{svc.agent.agent_id}")
        vm_manipulator.associate_address(svc.agent.agent_id, @elastic_ip)
      end

      def start
        system(Wakame.config.root +  '/config/init.d/apache2-lb start')
      end
      
      def check
        system("for i in `pidof apache2`; do ps -f $i; done | egrep -e '-DLB' >/dev/null")
        return false if $?.to_i != 0
        true
      end
      
      def stop
        system(Wakame.config.root + "/config/init.d/apache2-lb stop")
      end

      def reload
        system(Wakame.config.root +  '/config/init.d/apache2-lb reload')
      end
      
    end

    class MySQL_Master < Property
      attr_reader :basedir, :mysqld_datadir, :mysqld_port, :mysqld_server_id, :mysqld_log_bin, :ebs_volume, :ebs_device

      def initialize
        super()
        @template = ConfigurationTemplate::MySQLTemplate.new()
        @basedir = '/home/wakame/mysql'

        @mysqld_server_id = 1 # static
        @mysqld_port = 3306
        @mysqld_datadir = File.expand_path('data', @basedir)
        @mysqld_log_bin = File.expand_path('mysql-bin.log', @mysqld_datadir)
        @ebs_volume = ''
        @ebs_device = '/dev/sdm'
        @ebs_mount_option = 'noatime'

        @duplicable = false
      end

      def before_start(svc, action)
        vm_manipulator = VmManipulator.create
        res = vm_manipulator.describe_volume(@ebs_volume)

        # $ echo "GRANT REPLICATION SLAVE, REPLICATION CLIENT, RELOAD ON *.* TO 'wakame-repl'@'%' IDENTIFIED BY 'wakame-slave';" | /usr/bin/mysql -h#{mysql_master_ip} -uroot

        # in-use:
        ec2_instance_id = nil
        if res["attachmentSet"]
          ec2_instance_id = res["attachmentSet"]['item'][0]["instanceId"]
        end

        Wakame.log.debug("describe_volume(#{@ebs_volume}): #{res.inspect}")
        ec2_instance_id=nil
        if res['attachmentSet']
          ec2_instance_id = res['attachmentSet']['item'][0]['instanceId']
        end

        if res['status'] == 'in-use' && ec2_instance_id == svc.agent.agent_id
          # Nothin to be done
        elsif res['status'] == 'in-use' && ec2_instance_id != svc.agent.agent_id
          vm_manipulator.detach_volume(@ebs_volume)
          sleep 1.0
          res = vm_manipulator.attach_volume(svc.agent.agent_id, @ebs_volume, @ebs_device)
          Wakame.log.debug(res.inspect)
          # sync
          3.times do |i|
            system("/bin/sync")
            sleep 1.0
          end
        elsif res['status'] == 'available'
          res = vm_manipulator.attach_volume(svc.agent.agent_id, @ebs_volume, @ebs_device)
          Wakame.log.debug(res.inspect)
          # sync
          3.times do |i|
            system("/bin/sync")
            sleep 1.0
          end
        else
          raise "The EBS volume is not ready to attach: #{@ebs_volume}"
        end

      end

      def start
        mount_point_dev=`df "#{@mysqld_datadir}" | awk 'NR==2 {print $1}'`
        if mount_point_dev != @ebs_device
          Wakame.log.debug("Mounting EBS volume: #{@ebs_device} as #{@mysqld_datadir} (with option: #{@ebs_mount_option})")
          system("/bin/mount -o #{@ebs_mount_option} #{@ebs_device} #{@mysqld_datadir}")
          # sync
          3.times do |i|
            system("/bin/sync")
            sleep 1.0
          end
        end
        system(Wakame.config.root + "/config/init.d/mysql start")
      end
      
      def check
        system("/usr/bin/mysqladmin --defaults-file=/home/wakame/config/mysql/my.cnf ping > /dev/null")
        return false if $? != 0
        true
      end
      
      def stop
        system(Wakame.config.root + "/config/init.d/mysql stop")
      end
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
