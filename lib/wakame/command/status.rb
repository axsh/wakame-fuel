
require 'erb'

class Wakame::Command::Status
  include Wakame::Command

  STATUS_TMPL =<<__E__
Cluster : <%= @service_cluster[:name].to_s %> (<%= @service_cluster[:status].to_s %>)
<%- @service_cluster[:properties].each { |prop, v| -%>
  <%= v[:type].to_s %> : <current=<%= v[:instance_count] %> min=<%= v[:min_instances] %>, max=<%= v[:max_instances] %>> 
  <%- v[:instances].each { |id|
         svc_inst = @service_cluster[:instances][id]
  -%>
     <%= svc_inst[:instance_id] %> (<%= trans_svc_status(svc_inst[:status]) %>)
  <%- } -%>
<%- } -%>
<%- if @service_cluster[:instances].size > 0  -%>

Instances :
  <%- @service_cluster[:instances].each { |k, v| -%>
  <%= v[:instance_id] %> : <%= v[:property] %> (<%= trans_svc_status(v[:status]) %>)
    <%- if v[:agent_id ] -%>
    On VM instance: <%= v[:agent_id ]%>
    <%- end -%>
  <%- } -%>
<%- end -%>
<%- if @agent_monitor[:registered].size > 0 -%>

Agents :
  <%- @agent_monitor[:registered].each { |a| -%>
  <%= a[:agent_id] %> : <%= a[:attr][:local_ipv4] %>, <%= a[:attr][:public_ipv4] %> load=<%= a[:attr][:uptime] %>, <%= (Time.now - a[:last_ping_at]).to_i %> sec(s) (<%= a[:status] %>)
    <%- if !a[:services].nil? && a[:services].size > 0 -%>
    Services (<%= a[:services].size %>): <%= a[:services].collect{|id| @service_cluster[:instances][id][:property] }.join(', ') %>
    <%- end -%>
  <%- } -%>
<%- end -%>
__E__

  SVC_STATUS_MSG={
    Wakame::Service::STATUS_OFFLINE=>'Offline',
    Wakame::Service::STATUS_ONLINE=>'ONLINE',
    Wakame::Service::STATUS_UNKNOWN=>'Unknown',
    Wakame::Service::STATUS_FAIL=>'Fail',
    Wakame::Service::STATUS_STARTING=>'Starting...',
    Wakame::Service::STATUS_STOPPING=>'Stopping...',
    Wakame::Service::STATUS_RELOADING=>'Reloading...',
    Wakame::Service::STATUS_MIGRATING=>'Migrating...',
  }
  
  def parse(args)
  end

  def run(rule)
    EM.barrier {
      master = rule.master
      
      sc = master.service_cluster
      #result = {
      #  :rule_engine => {
      #    :rules => sc.rule_engine.rules
      #  },
      #  :service_cluster => sc.dump_status,
      #  :agent_monitor => master.agent_monitor.dump_status
      #}

      @service_cluster = master.service_cluster.dump_status
      @agent_monitor = master.agent_monitor.dump_status
    }
  end
  
  def print_result
    puts ERB.new(STATUS_TMPL, nil, '-').result(binding)
  end


  private
  def trans_svc_status(stat)
    SVC_STATUS_MSG[stat]
  end
  
end
