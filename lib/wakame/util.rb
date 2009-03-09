

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
