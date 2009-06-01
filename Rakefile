# -*- ruby -*-

%w[rubygems rake rake/clean fileutils hoe].each { |f| require f }
$:.unshift "#{File.dirname(__FILE__)}/lib"

require 'wakame'

# Generate all the Rake tasks
# Run 'rake -T' to see list of generated tasks (from gem root directory)
$hoe = Hoe.new('wakame', Wakame::VERSION) do |p|
  p.author = ["axsh co., LTD"]
  p.developer('Masahiro Fujiwara', 'm-fujiwara at axsh dot net')
  p.summary = "A distributed service framework on top of Cloud environment."
  p.url = "http://wakame.rubyforge.org/"
  #p.changes              = p.paragraphs_of("History.txt", 0..1).join("\n\n")
  #p.post_install_message = 'PostInstall.txt' # TODO remove if post-install message not required
  p.extra_deps         = [
     ['amqp','>= 0.6.0'],
     ['amazon-ec2','>= 0.3.6'],
     ['eventmachine','>= 0.12.8'],
     ['rake', '>= 0.8.4'],
     ['log4r'],
     ['daemons'],
     ['rubigen', '>= 1.5.2'],
     ['hoe', ">= 1.12.0"]
  ]
  p.extra_dev_deps = [
  ]
  
  p.clean_globs |= %w[**/.DS_Store tmp *.log]
  path = (p.rubyforge_name == p.name) ? p.rubyforge_name : "\#{p.rubyforge_name}/\#{p.name}"
  p.remote_rdoc_dir = File.join(path.gsub(/^#{p.rubyforge_name}\/?/,''), 'rdoc')
  p.rsync_args = '-av --delete --ignore-errors'
end

desc "Generate a #{$hoe.name}.gemspec file"
task :gemspec do
  File.open("#{$hoe.name}.gemspec", "w") do |file|
    file.puts $hoe.spec.to_ruby
  end
end

Dir['tasks/**/*.rake'].each { |t| load t }

# task :default => [:spec, :features]
# vim: syntax=Ruby
