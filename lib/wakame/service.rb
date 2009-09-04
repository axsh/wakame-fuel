#!/usr/bin/ruby

require 'ostruct'

require 'wakame'
require 'wakame/util'

module Wakame
  module Service
    class ServiceError < StandardError; end
    class ServiceOk < StandardError; end
    class ServicePropagationError < ServiceError; end


    STATUS_END     = -2
    STATUS_INIT    = -1
    STATUS_OFFLINE = 0
    STATUS_ONLINE  = 1
    STATUS_UNKNOWN = 2
    STATUS_FAIL    = 3
    STATUS_STARTING = 4
    STATUS_STOPPING = 5
    STATUS_RELOADING = 6
    STATUS_MIGRATING = 7

    # Data model for agent
    # Status life cycle:
    # STATUS_INIT -> [STATUS_ONLINE|STATUS_OFFLINE|STATUS_TIMEOUT] -> STATUS_END
    class Agent < StatusDB::Model
      STATUS_END     = -1
      STATUS_INIT    = -2
      STATUS_OFFLINE = 0
      STATUS_ONLINE  = 1
      STATUS_UNKNOWN = 2
      STATUS_TIMEOUT = 3
      
      property :last_ping_at
      property :vm_attr
      property :root_path
      property :status, {:read_only=>true, :default=>STATUS_INIT}
      property :reported_services, {:read_only=>true, :default=>{}}
      property :host_id

      def mapped?
        !self.host_id.nil?
      end

      def id=(agent_id)
        @id = agent_id
      end

      def id
        @id || raise("Agent.id is unset: #{self}")
      end

      def agent_ip
        vm_attr[:local_ipv4]
      end

      def vm_id
        vm_attr[:instance_id]
      end

      # Tentative...
      def last_ping_at_time
        require 'time'
        Time.parse(last_ping_at)
      end

      def update_status(new_status)
        if @status != new_status
          @status = new_status
          self.save

          ED.fire_event(Event::AgentStatusChanged.new(self))
          # Send status specific event
          case @status
          when STATUS_TIMEOUT
            ED.fire_event(Event::AgentTimedOut.new(self))
          end
        end
      end


      def renew_reported_services(svc_id_list)
        reported_services.clear
        svc_id_list.each { |svc_id, data|
          reported_services[svc_id] = data
        }
      end

      def has_resource_type?(key)
        res_id = key.is_a?(ServiceInstance) ? key.resource.id : Resource.id(key)

        reported_services.any? { |k|
          svc = ServiceInstance.find(k)
          svc.resource.id == res_id
        }
      end
    end


    class AgentPool < StatusDB::Model
      property :group_observed, {:default=>{}}
      property :group_active, {:default=>{}}

      ID=self.to_s

      def self.instance
        a = self.find(ID)
        if a.nil?
          a = self.new
          a.save
        end
        a
      end

      def self.reset
        ap = self.instance
        ap.group_observed = {}
        ap.group_active = {}
        ap.save
      end


      def id
        ID
      end

      def create_or_find(agent_id)
        agent = Service::Agent.find(agent_id)
        if agent.nil?
          agent = Service::Agent.new
          agent.id = agent_id
          Wakame.log.debug("#{self.class}: Created new agent object with Agent ID: #{agent_id}")
        end
        agent
      end

      def register_as_observed(agent)
        agent_id = agent.id
        if group_observed.has_key?(agent_id)
        else
          if group_active.has_key?(agent_id)
            # Move the reference from unregistered group to the registered group.
            group_active.delete(agent_id)
            group_observed[agent_id]=1
          else
            # The agent is going to be registered at first time.
            group_observed[agent_id]=1
          end

          self.save
          Wakame.log.debug("#{self.class}: Register agent to observed group: #{agent_id}")
        end
      end

      def register(agent)

        agent_id = agent.id
        if group_active.has_key?(agent_id)
        else
          if group_observed.has_key?(agent_id)
            # Move the reference from unregistered group to the registered group.
            group_observed.delete(agent_id)
            group_active[agent_id]=1
          else
            # The agent is going to be registered at first time.
            group_active[agent_id]=1
          end

          self.save

          Wakame.log.debug("#{self.class}: Register agent to active group: #{agent_id}")
          ED.fire_event(Event::AgentMonitored.new(agent))
        end
      end

      def unregister(agent)
        agent_id = agent.id
        
        unregistered = false
        if group_active.has_key?(agent_id)
          group_active.delete(agent_id)
          unregistered = true
        end

        if group_observed.has_key?(agent_id)
          group_observed.delete(agent_id)
          unregistered = true
        end

        if unregistered
          self.save
          
          Wakame.log.debug("#{self.class}: Unregister agent: #{agent.id}")
          ED.fire_event(Event::AgentUnMonitored.new(agent))
        end
      end

    end

    class Host < StatusDB::Model
      property :agent_id

      # cluster_id will not become nil since ServiceCluster has responsibility for the lifecycle of this class.
      property :cluster_id
      
      # Virtual Machine attributes specified by Resource object.
      property :vm_attr, {:default=>{}}

      def mapped?
        !self.agent_id.nil?
      end
        
      def map_agent(agent)
        raise TypeError unless agent.is_a?(Agent)
        raise "Ensure to call unmap_agent() prior to mapping new agent" if self.mapped?
        raise "The agent \"#{agent.id}\" is already mapped to the host: #{agent.host_id}" if agent.mapped?

        self.agent_id = agent.id
        agent.host_id = self.id

        self.save
        agent.save
      end

      def unmap_agent()
        if mapped?
          agent = Agent.find(self.agent_id)
          if agent && self.agent_id == agent.id
            agent.host_id = nil
            agent.save
          end

          self.agent_id = nil
          self.save
        end
      end

      def agent
        raise "#{self.class}: Agent is not mapped yet to this Host \"#{self.id}\"." unless mapped?
        Agent.find(self.agent_id) || raise("#{self.class}: Could not find the mapped agent: Host.id \"#{self.id}\"")
      end

      def vm_spec
        spec = VmSpec.current
        spec.table = self.vm_attr
        spec
      end


      # Delegate methods for Agent class

      def status
        self.agent.status
      end

      def reported_services
        self.agent.reported_services
      end

      def root_path
        self.agent.root_path
      end

      def agent_ip
        self.agent.agent_ip
      end

      def has_resource_type?(key)
        res_id = key.is_a?(ServiceInstance) ? key.resource.id : Resource.id(key)

        assigned_services.any? { |k|
          svc = ServiceInstance.find(k)
          svc.resource.id == res_id
        }
      end

      def assigned_services()
        cluster = ServiceCluster.find(self.cluster_id)
        cluster.services.keys.find_all { |svc_id| ServiceInstance.find(svc_id).host_id == self.id }
      end

      def assigned_resources()
        assigned_services.map { |svc_id|
          ServiceInstance.find(svc_id).resource
        }.uniq
      end

      def validate_on_save
        raise "Host.cluster_id property can't be nil." if self.cluster_id.nil?
      end

    end


    class ServiceCluster < StatusDB::Model
      include ThreadImmutable

      STATUS_OFFLINE = 0
      STATUS_ONLINE = 1
      STATUS_PARTIAL_ONLINE = 2

      property :name
      property :status, {:readonly=>true, :default=>STATUS_OFFLINE}
      property :status_changed_at, {:readonly=>true, :default=>proc{Time.now} }
      property :services, {:default=>{}}
      property :resources, {:default=>{}}
      property :hosts, {:default=>{}}
      property :dg_id
      property :template_vm_attr, {:default=>{}}
      property :advertised_amqp_servers

      attr_reader :rule_engine

      def self.id(name)
        require 'digest/sha1'
        Digest::SHA1.hexdigest(name)
      end

      def id
        raise "Cluster name is not set yes" if self.name.nil?
        self.class.id(self.name)
      end

      def define_rule(&blk)
        @rule_engine ||= RuleEngine.new(self.id)
        
        blk.call(@rule_engine)
      end

      def template_vm_spec
        spec = VmSpec.current
        spec.table = self.template_vm_attr
        spec
      end

      def reset
        services.clear
        resources.clear
        hosts.clear
        @status = self.class.attr_attributes[:status][:default]
        @status_changed_at = Time.now
      end

      def mapped_agent?(agent_id)
        hosts.keys.any? { |host_id|
          h = Host.find(host_id)
          h.mapped? && h.agent_id == agent_id
        }
      end

      def agents
        res={}
        hosts.keys.collect { |host_id|
          h = Host.find(host_id)
          res[host_id]=h.agent_id if h.mapped?
        }
        res
      end

      def dg
        unless self.dg_id.nil?
          graph = DependencyGraph.find(self.dg_id)
        else
          graph = DependencyGraph.new
          graph.save
          self.dg_id = graph.id
          self.save
        end
        graph
      end

      # 
      def add_resource(resource, &blk)
        if resource.is_a?(Class) && resource <= Resource
          resource = resource.new
        elsif resource.is_a? Resource
        else
          raise ArgumentError
        end
        raise "Duplicate resource registration: #{resource.class}" if self.resources.has_key? resource.id

        blk.call(resource) if blk

        resources[resource.id]=1
        self.dg.add_object(resource)

        resource.save
        self.save
        self.dg.save
        resource
      end
      thread_immutable_methods :add_resource

      # Set dependency between two resources.
      def set_dependency(res_name1, res_name2)
        validate_arg = proc {|o|
          o = Utils.build_const(o) if o.is_a? String
          raise ArgumentError unless o.is_a?(Class) && o <= Resource
          raise "This is not a member of this cluster \"#{self.class}\": #{o}" unless resources.member?(o.id)
          raise "Unknown resource object: #{o}" unless Resource.exists?(o.id)
          o
        }
        
        res_name1 = validate_arg.call(res_name1)
        res_name2 = validate_arg.call(res_name2)
        
        return if res_name1.id == res_name2.id

        self.dg.set_dependency(res_name1, res_name2)
      end
      thread_immutable_methods :set_dependency

      def has_instance?(svc_id)
        self.services.has_key? svc_id
      end

      def shutdown
      end
      thread_immutable_methods :shutdown

      # Create service instance objects which will be equivalent with the number min_instance.
      # The agents are not assigned at this point.
      def launch
        self.resources.keys.each { |res_id|
          res = Resource.find(res_id)
          count = instance_count(res.class)
          if res.min_instances > count
            (res.min_instances - count).times {
              propagate(res.class)
            }
          end
        }
      end
      thread_immutable_methods :launch

      def destroy(svc_id)
        raise("Unknown service instance : #{service_instance_id}") unless self.services.has_key?(svc_id)
        svc = ServiceInstance.find(svc_id)
        svc.unbind_cluster
        self.services.delete(svc.id)
        old_host = svc.unbind_host

        if old_host
          Wakame.log.debug("#{svc.resource.class}(#{svc.id}) has been destroied from Host #{old_host.inspect}")
        else
          Wakame.log.debug("#{svc.resource.class}(#{svc.id}) has been destroied.")
        end

        svc.delete
        self.save
      end
      thread_immutable_methods :destroy


      #def propagate(resource, force=false)
      def propagate(resource, host_id=nil, force=false)
        res_id = Resource.id(resource)
        res_obj = (self.resources.has_key?(res_id) && Resource.find(res_id)) || raise("Unregistered resource: #{resource.to_s}")

        if force == false
          instnum = instance_count(res_obj)
          if instnum >= res_obj.max_instances
            raise ServicePropagationError, "#{res_obj.class} has been reached to max_instance limit: max=#{res_obj.max_instances}" 
          end
        end
        
        svc = ServiceInstance.new
        svc.bind_cluster(self)
        svc.bind_resource(res_obj)

        if res_obj.require_agent
          host = Host.find(host_id) || raise("#{self.class}: Unknown Host ID: #{host_id}")
          svc.bind_host(host)
        end

        self.services[svc.id]=1

        svc.save
        self.save

        svc
      end
      thread_immutable_methods :propagate

      def propagate_service(svc_id, host_id=nil, force=false)
        src_svc = (self.services.has_key?(svc_id) && ServiceInstance.find(svc_id)) || raise("Unregistered service: #{svc_id.to_s}")
        res_obj = src_svc.resource

        if force == false
          instnum = instance_count(res_obj)
          if instnum >= res_obj.max_instances
            raise ServicePropagationError, "#{res_obj.class} has been reached to max_instance limit: max=#{res_obj.max_instances}" 
          end
        end
        
        svc = ServiceInstance.new
        svc.bind_cluster(self)
        svc.bind_resource(res_obj)

        if res_obj.require_agent
          if host_id
            host = Host.find(host_id) || raise("#{self.class}: Unknown Host ID: #{host_id}")
          else
            host = add_host { |h|
              h.vm_attr = src_svc.host.vm_attr.dup
            }
          end
          svc.bind_host(host)
        end

        self.services[svc.id]=1

        svc.save
        self.save

        svc
      end
      #thread_immutable_methods :propagate

      def add_host(&blk)
        h = Host.new
        h.cluster_id = self.id
        self.hosts[h.id]=1

        blk.call(h) if blk

        h.save
        self.save

        h
      end

      def del_host(host_id)
        if self.hosts.has_key?(host_id)
          self.hosts.delete(host_id)
        
          self.save
        end

        Host.delete(host_id) rescue nil

      end


      def instance_count(resource=nil)
        return self.services.size if resource.nil?

        c = 0
        each_instance(resource) { |svc|
          c += 1
        }
        c
      end

      # Iterate the service instances in this cluster
      #
      # The first argument is used for filtering only specified resource instances. 
      # Iterated instance objects are passed to the block when it is given. The return value is an array contanins registered service instance objects (filtered).
      def each_instance(filter_resource=nil, &blk)
        filter_resource = case filter_resource 
                          when Resource
                            filter_resource.class
                          when String
                            Util.build_const(filter_resource)
                          when Module, NilClass
                            filter_resource
                          else
                            raise ArgumentError, "The first argument has to be in form of NilClass, Resource, String or Module: #{filter_resource.class}"
                          end

        filter_ids = []

        unless filter_resource.nil?
          filter_ids = self.resources.keys.find_all { |resid|
            Resource.find(resid).kind_of?(filter_resource)
          }
          return [] if filter_ids.empty?
        end
        
        ary = self.services.keys.collect {|k| ServiceInstance.find(k) }
        if filter_resource.nil?
        else
          ary = ary.find_all{|v| filter_ids.member?(v.resource.id) }
        end

        ary.each {|v| blk.call(v) } if block_given?
        ary
      end

      def update_status(new_status)
        if @status != new_status
          @status = new_status
          @status_changed_at = Time.now

          self.save

          ED.fire_event(Event::ClusterStatusChanged.new(id, new_status))
        end
      end
      thread_immutable_methods :update_status

      def size
        self.dg.size
      end

      def properties
        self.resources
      end

      alias :instances :services

      #private

      def update_cluster_status
        onlines = []
        all_offline = false

        onlines = self.each_instance.select { |i|
          i.status == Service::STATUS_ONLINE
        }
        all_offline = self.each_instance.all? { |i|
          i.status == Service::STATUS_OFFLINE
        }
        #Wakame.log.debug "online instances: #{onlines.size}, assigned instances: #{self.instances.size}"

        prev_status = self.status
        if self.instances.size == 0 || all_offline
          self.update_status(Service::ServiceCluster::STATUS_OFFLINE)
        elsif onlines.size == self.instances.size
          self.update_status(Service::ServiceCluster::STATUS_ONLINE)
        elsif onlines.size > 0
          self.update_status(Service::ServiceCluster::STATUS_PARTIAL_ONLINE)
        end

      end
      thread_immutable_methods :update_cluster_status

    end

    
    class DependencyGraph < StatusDB::Model
      
      property :nodes, {:default=>{}}
      property :graph_edges

      def initialize()
        @graph = Graph.new
        @graph.edges = self.graph_edges = {}
        @graph.add_vertex(0)
      end
      
      def add_object(obj)
        res_id = Resource.id(obj)
        self.nodes[res_id.hash] = res_id
        @graph.add_edge(0, res_id.hash)
        self.save
        self
      end
      
      def set_dependency(parent_res, child_res)
        p_res_id = Resource.id(parent_res)
        c_res_id = Resource.id(child_res)
        return if p_res_id == c_res_id

        self.nodes[p_res_id.hash]=p_res_id
        self.nodes[c_res_id.hash]=c_res_id

        @graph.add_edge(p_res_id.hash, c_res_id.hash)
        @graph.remove_edge(0, c_res_id.hash) if @graph.has_edge?(0, c_res_id.hash)
        self.save
        self
      end

      #
      def size
        @graph.size - 1
      end

      # Returns an array with the parent resources of given node
      def parents(res)
        # delete() returns nil when nothing was removed. so use delete_if instead.
        @graph.parents(Resource.id(res).hash).delete_if{|i| i == 0}.collect { |hashid| id2obj(hashid) }
      end

      # Returns an array with the child resources of given node
      def children(res)
        # delete() returns nil when nothing was removed. so use delete_if instead.
        @graph.children(Resource.id(res).hash).delete_if{|i| i == 0}.collect { |hashid| id2obj(hashid) }
      end
      
      def levels(root=nil)
        root = root.nil? ? 0 : Resource.id(root).hash

        n=[]
        @graph.level_layout(root).each { |l|
          next if l.size == 1 && l[0] == 0
          n << l.collect { |hashid| id2obj(hashid) }
        }
        n
      end
      
      def each_level(root=nil, &blk)
        root = root.nil? ? 0 : Resource.id(root).hash

        @graph.level_layout(root).each { |l|
          l.each { |hashid|
            next if hashid == 0
            blk.call(id2obj(hashid))
          }
        }
      end

      def on_after_load
        # Delegate the edge data to be handled by Graph class when it is loaded from database.
        @graph.edges = self.graph_edges
      end
      
      private
      def id2obj(hashid)
        Resource.find(self.nodes[hashid])
      end
    end
    

    # The data model represents a service instance.
    # Status transition:
    # STATUS_INIT -> [STATUS_OFFLINE|STATUS_ONLINE|STATUS_FAIL] -> STATUS_END
    # Progress status:
    # STATUS_NONE, STATUS_MIGRATING, STATUS_PROPAGATING,
    class ServiceInstance < StatusDB::Model
      include ThreadImmutable

      property :host_id
      property :resource_id
      property :cluster_id
      property :status, {:read_only=>true, :default=>Service::STATUS_INIT}
      property :progress_status, {:read_only=>true, :default=>Service::STATUS_INIT}
      property :status_changed_at, {:read_only=>true, :default=>proc{Time.now}}

      def update_status(new_status, changed_at=Time.now, fail_message=nil)
        if @status != new_status
          prev_status = @status
          @status = new_status
          @status_changed_at = changed_at
          
          self.save

          event = Event::ServiceStatusChanged.new(@instance_id, resource, new_status, prev_status)
          event.time = @status_changed_at.dup
          ED.fire_event(event)

          tmp_event = nil
          if prev_status != Service::STATUS_ONLINE && new_status == Service::STATUS_ONLINE
            tmp_event = Event::ServiceOnline.new(self.id, self.resource)
            tmp_event.time = @status_changed_at.dup
          elsif prev_status != Service::STATUS_OFFLINE && new_status == Service::STATUS_OFFLINE
            tmp_event = Event::ServiceOffline.new(self.id, self.resource)
            tmp_event.time = @status_changed_at.dup
          elsif prev_status != Service::STATUS_FAIL && new_status == Service::STATUS_FAIL
            tmp_event = Event::ServiceFailed.new(self.id, self.resource, fail_message)
            tmp_event.time = @status_changed_at.dup
          end
          ED.fire_event(tmp_event) if tmp_event

        end
      end

      
      def host
        if self.resource.require_agent
          
        elsif self.host_id.nil?
          return nil
        end
        Host.find(self.host_id)
      end

      def bind_host(new_host)
        # UboundHost & BoundHost events occured only when the different agent object is assigned.
        return if !self.resource.require_agent || self.host_id == new_host.id
        raise "The host (#{host.id}) was assigned same service already: #{resource.class}" if new_host.has_resource_type?(resource)
        
        unbind_host

        self.host_id = new_host.id
        self.save
        
        ED.fire_event(Event::ServiceBoundHost.new(self, host))
      end
      thread_immutable_methods :bind_host
      
      def unbind_host
        return if self.host_id.nil?

        old_item = self.host
        self.host_id = nil
        
        self.save

        ED.fire_event(Event::ServiceUnboundHost.new(self, old_item))
        old_item
      end
      thread_immutable_methods :unbind_host

      def resource
        return nil if self.resource_id.nil?
        Resource.find(self.resource_id)
      end
      
      def bind_resource(resource)
        return if self.resource_id == resource.id

        unbind_resource
        self.resource_id = resource.id
        self.save

        #ED.fire_event(Event::ServiceBoundCluster.new(self, cluster))
      end
      thread_immutable_methods :bind_resource

      def unbind_resource
        return if self.resource_id.nil?
        old_item = self.resource_id

        self.resource_id = nil
        self.save

        #ED.fire_event(Event::ServiceUnboundCluster.new(self, old_item))
        old_item
      end
      thread_immutable_methods :unbind_resource


      def cluster
        return nil if self.cluster_id.nil?
        ServiceCluster.find(self.cluster_id)
      end

      def bind_cluster(cluster)
        return if self.cluster_id == cluster.id

        unbind_cluster
        self.cluster_id = cluster.id
        self.save

        ED.fire_event(Event::ServiceBoundCluster.new(self, cluster))
      end
      thread_immutable_methods :bind_cluster

      def unbind_cluster
        return if self.cluster_id.nil?
        old_item = self.cluster_id

        self.cluster_id = nil
        self.save

        ED.fire_event(Event::ServiceUnboundCluster.new(self, old_item))
        old_item
      end
      thread_immutable_methods :unbind_cluster
      
      def export_binding
        binding
      end
      
      def parent_instances
        ary = []
        self.cluster.dg.parents(resource.class).each { |r|
          self.cluster.each_instance(r.class){ |i|
            ary << i
          }
        }
        ary.flatten
      end
      
      def child_instances
        ary = []
        self.cluster.dg.children(resource.class).each { |r|
          self.cluster.each_instance(r.class){ |i|
            ary << i
          }
        }
        ary.flatten
      end
    end


    class VmSpec < OpenStruct
      def self.current
        environment(Wakame.config.environment)
      end

      def self.environment(klass_key)
        @templates ||= {}

        tmpl_klass = @templates[klass_key]
        if tmpl_klass.nil?
          #klass = self.class.constants.find{ |c| c.to_s == klass_key.to_s }
          if self.const_defined?(klass_key)
            tmpl_klass = @templates[klass_key] = Util.build_const([self.to_s, klass_key.to_s].join('::'))
          else
            raise "Undefined VM Spec Template : #{klass_key}"
          end
        end

        self.new(tmpl_klass.new)
      end


      def initialize(template, vm_attr=nil)
        @template = template
        if vm_attr.is_a? Hash
          @table = vm_attr
        else
          h = {}
          @template.class.vm_attr_defs.keys.each {|k| h[k]=nil }
          super(h)
        end
      end
      protected :initialize
      
      def table=(vm_attr)
        @table = vm_attr
      end
      
      def attrs
        table
      end
      
      def satisfy?(vm_attr)
        @template.satisfy?(vm_attr, table)
      end
      
      def merge(src_vm_attr)
        @template.merge(src_vm_attr, table)
      end
      


      class Template
        def self.inherited(klass)
          klass.class_eval {
            def self.vm_attr_defs
              @vm_attr_defs ||= {}
            end
          
            def self.vm_attr(key, opts=nil)
              opts ||= {}

              vm_attr_defs[key.to_sym]=opts
            end
          }
          
        end

        def satisfy?(vm_attr, diff)
          raise ""
        end

        def merge(src_vm_attr, diff)
          raise ""
        end

      end

      class EC2 < Template
        AWS_VERSION=''
        vm_attr :instance_type, {:choice=>%w[m1.small m1.large m1.xlarge c1.medium c1.xlarge], :right_aws_key=>:aws_instance_type}
        vm_attr :availability_zone, {:right_aws_key=>:aws_availability_zone}
        vm_attr :key_name, {:right_aws_key=>:ssh_key_name}
        vm_attr :security_groups, {:default=>['default'], :right_aws_key=>:aws_groups}
        vm_attr :image_id, {:right_aws_key=>:aws_image_id}


        def satisfy?(vm_attr, diff)
          # Compare critical variables which will return false if they are not same.
          return false unless [:availability_zone, :instance_type, :image_id].all? { |k| diff[k].nil? ? true : diff[k] == vm_attr[k] }
          true
        end

        def merge(vm_attr, diff)
          self.class.vm_attr_defs.each_key { |k|
            raise "Passed VM attribute hash is incomplete data set: #{vm_attr}" unless vm_attr.has_key? k
          }

          merged = vm_attr.merge(diff){ |k,v1,v2|
            case k
            when :security_groups
              if v1.is_a?(Array)
                (v1.dup << v2).flatten.uniq
              else
                v2
              end
            else
              v2.nil? ? v1 : v2
            end
          }

          merged
        end
      end

      class StandAlone < Template
      end
    end


    class Resource < StatusDB::Model
      property :duplicable, {:default=>true}
      property :min_instances, {:default=>1}
      property :max_instances, {:default=>1}
      property :startup, {:default=>true}
      property :require_agent, {:default=>true}

      def self.inherited(klass)
        klass.class_eval {
          def self.id
            Resource.id(self)
          end
        }
      end

      def self.name(id)
        find(id).class.to_s
      end

      # Returns the hashed resource class name representation.
      #   Resource.id() is as same as sha1.digest('Wakame::Service::Resource')
      #   With an argument, tries to get the class name and take digest.
      def self.id(name=nil)
        res_class_name = case name
                         when nil
                           self.to_s
                         when String
                           raise "Invalid string as ruby constant: #{name}" unless name =~ /^(:-\:\:)?[A-Z]/
                           name.to_s
                         when Class
                           raise "Can't convert the argument: type of #{name.class}" unless name <= self
                           name.to_s
                         when Resource
                           name.class.to_s
                         else
                           raise "Can't convert the argument: type of #{name.class}"
                         end

        require 'digest/sha1'
        Digest::SHA1.hexdigest(res_class_name)
      end
      
      def id
        Resource.id(self.class.to_s)
      end

      def basedir
        File.join(Wakame.config.root_path, 'cluster', 'resources', Util.snake_case(self.class))
      end

      def start(service_instance, action); end
      def stop(service_instance, action); end
      def reload(service_instance, action); end

      def render_config(template)
      end

      def on_child_changed(service_instance, action)
      end
      def on_parent_changed(service_instance, action)
      end

    end

    Property = Resource
  end
end

module Wakame
  module Service
    module ApacheBasicProps
      attr_accessor :listen_port, :listen_port_https, :server_root
    end
  end
end
