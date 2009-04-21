#!/usr/bin/env ruby

require File.dirname(__FILE__) + '/../config/boot'

require 'wakame'

AWS_ACCESS_KEY=ENV['AMAZON_ACCESS_KEY_ID'] || Wakame.config.aws_access_key
AWS_SECRET_KEY=ENV['AMAZON_SECRET_ACCESS_KEY'] || Wakame.config.aws_secret_key

def create_ec2
  require 'EC2'
  ec2 = EC2::Base.new(:access_key_id =>AWS_ACCESS_KEY, :secret_access_key =>AWS_SECRET_KEY)
end

def request_metadata_url(key)
  require 'open-uri'
  open("http://169.254.169.254/2008-09-01/meta-data/#{key}") { |f|
    return f.readline
  }
end

namespace :ec2 do
  desc "Automate the EC2 image bundle procedure.(ec2-bundle-vol + ec2-upload-bundle + ec2-register)"
  task :bundle, :manifest_path do |t, args|
    raise 'This task has to be run with root.' unless Process.uid == 0
    raise 'Required key files counld not be detected: /mnt/cert.pem or /mnt/pk.pem'  unless File.exist?('/mnt/cert.pem') && File.exist?('/mnt/pk.pem')

    bundle_tmpdir='/mnt/wakame-bundle'
    # If the arg was not set, it tries to overwrite the running image.
    manifest_path= args.manifest_path || request_metadata_url('ami-manifest-path')

    #manifest_path.sub!(/.manifest.xml\Z/, '')
    if manifest_path =~ %r{\A([^/]+)/(.+)\.manifest\.xml\Z}
      #s3bucket = manifest_path[0, manifest_path.index('/') - 1]
      #manifest_prefix = manifest_path[manifest_path.index('/')]
      s3bucket = $1
      manifest_basename = File.basename($2)
      manifest_path = "#{s3bucket}/#{manifest_basename}.manifest.xml"
      #puts "#{manifest_path}"
    else
      fail "Given manifest path is not valid: #{manifest_path}"
    end

    puts "Manifest Path: #{manifest_path}"

    ec2 = create_ec2()

    ami_id = request_metadata_url('ami-id')

    instance_id = request_metadata_url('instance-id')
    res = ec2.describe_instances(:instance_id=>instance_id)
    account_no = res['reservationSet']['item'][0]['ownerId']

    res = ec2.describe_images(:image_id=>ami_id)
    arch = res['imagesSet']['item'][0]['architecture']

    begin
      FileUtils.mkpath(bundle_tmpdir) unless File.exist?(bundle_tmpdir)

      sh("ec2-bundle-vol --batch -d '#{bundle_tmpdir}' -p '#{manifest_basename}' -c /mnt/cert.pem -k /mnt/pk.pem -u '#{account_no}' -r '#{arch}'")
      sh("ec2-upload-bundle -d '#{bundle_tmpdir}' -b '#{s3bucket}' -m '#{File.join(bundle_tmpdir, manifest_basename + '.manifest.xml')}' -a '#{AWS_ACCESS_KEY}' -s '#{AWS_SECRET_KEY}'")
      res = ec2.register_image(:image_location=>manifest_path)
      puts "New AMI ID for #{manifest_path}: #{res['imageId']}"
    ensure
      FileUtils.rm_rf(bundle_tmpdir) if File.exist?(bundle_tmpdir)
    end
  end
end
