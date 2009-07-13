

require 'shellwords'
require 'ext/shellwords' unless Shellwords.respond_to? :shellescape

class Wakame::Actor::System
  include Wakame::Actor

  def sync(count = 1)
    count.to_i.times do |i|
      Wakame.log.debug("Wakame::Actor::System.sync #{i + 1}/#{count}")
      system("/bin/sync")
    end
  end

  def mount(dev, path, opts={})
    16.times do |i|
      break if File.blockdev?(dev)
      Wakame.log.debug("Wakame::Actor::System.mount sync=#{i}")
      self.sync
      sleep 1.0
    end

    raise "#{dev} does not exist or not block device." unless File.blockdev?(dev)
    raise "#{path} does not exist or not directory." unless File.directory?(path)
    
    mount_point_dev=`/bin/df "#{path}" | /usr/bin/awk 'NR==2 {print $1}'`.strip

    #mount_point_dev=`/bin/mount | /usr/bin/awk '$3==path {print $1}' path="#{path}"`.strip
    Wakame.log.debug("#{mount_point_dev}: #{dev}, /bin/mount | awk '$3==path {print $1}' path=\"#{path}\"")
    if mount_point_dev != dev
      Wakame.log.debug("Mounting volume: #{dev} as #{path} (with options: #{opts})")
      Wakame::Util.exec("/bin/mount -o #{mount_opts(opts)} '#{Shellwords.shellescape(dev)}' '#{Shellwords.shellescape(path)}'")
      # sync
#      3.times do |i|
#        system("/bin/sync")
#        sleep 1.0
#      end
    else
      Wakame.log.debug("Mounting EBS volume: #{dev} as #{path} (with options: #{opts})")
    end
  end

  def umount(path)
    raise "#{path} does not exist or not directory." unless File.directory?(path)

    mount_point_dev=`/bin/df "#{path}" | awk 'NR==2 {print $1}'`
    Wakame.log.debug("Unmounting volume: #{mount_point_dev} on #{path}")
    Wakame::Util.exec("/bin/umount '#{Shellwords.shellescape(path)}'")
  end
  
  private
  def mount_opts(opts)
    out = opts.collect { |k,v|
      v.nil? ? k : "#{k}=#{v}"
    }.join(',')
    Shellwords.shellescape(out)
  end

end

