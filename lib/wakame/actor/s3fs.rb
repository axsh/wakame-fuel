
require 'shellwords'
require 'ext/shellwords' unless Shellwords.respond_to? :shellescape

class Wakame::Actor::S3fs
  include Wakame::Actor

  def mount(bucket, path, opts={})
    Wakame.log.debug("Wakame::Actor::S3fs.mount")
    #return
    raise "#{path} does not exist or not directory." unless File.directory?(path)
    #  's3fs' or '/dev/xxx' ?
    mount_point_dev=`/bin/df "#{path}" | /usr/bin/awk 'NR==2 {print $1}'`.strip
    Wakame.log.debug("#{mount_point_dev}: #{bucket}, /bin/mount | awk '$3==path {print $1}' path=\"#{path}\"")

    if mount_point_dev != 's3fs'
      Wakame.log.debug("Mounting volume: #{bucket} as #{path} (with options: #{opts})")
      Wakame::Util.exec("/usr/local/sbin/s3fs #{escape_mount_opts(opts)} '#{Shellwords.shellescape(bucket)}' '#{Shellwords.shellescape(path)}'")
    else
      Wakame.log.debug("Mounting s3fs bucket: #{bucket} as #{path} (with options: #{opts})")
    end
  end

  def umount(path)
    Wakame.log.debug("Wakame::Actor::S3fs.umount")
    #return
    raise "#{path} does not exist or not directory." unless File.directory?(path)

    mount_point_dev=`/bin/df "#{path}" | awk 'NR==2 {print $1}'`
    Wakame.log.debug("Unmounting volume: #{mount_point_dev} on #{path}")
    Wakame::Util.exec("/bin/umount '#{Shellwords.shellescape(path)}'")
  end

  private
  def escape_mount_opts(opts)
    return '' if opts.nil?
    return "-o '#{Shellwords.shellescape(opts)}'" if opts.is_a? String

    out = opts.collect { |k,v|
      v.nil? ? k : "#{k}=#{v}"
    }.join(',')
    "-o #{Shellwords.shellescape(out)}"
  end

end
