# -*- ruby -*-
require 'rubygems'
require 'rake'
require 'rake/clean'

begin
  require 'jeweler'
  Jeweler::Tasks.new do |gem|
    gem.name = "wakame"
    gem.summary = %q{A distributed service framework on top of Cloud environments.}
    gem.description = <<__END__
__END__
    gem.email = ["m-fujiwara@axsh.net"]
    gem.homepage = "http://wakame.rubyforge.org/"
    gem.authors = ["axsh co.,Ltd.", "Masahiro Fujiwara"]
    # gem is a Gem::Specification... see http://www.rubygems.org/read/chapter/20 for additional settings
    gem.rubyforge_project = 'wakame'
    gem.executables = ['wakame']
    [['amqp','>= 0.6.0'],
     ['amazon-ec2','>= 0.3.6'],
     ['right_aws','>= 1.10.0'],
     ['eventmachine','>= 0.12.8'],
     ['rake', '>= 0.8.7'],
     ['log4r', '>= 1.0.5'],
     ['daemons', '>= 1.0.10'],
     ['rubigen', '>= 1.5.2'],
     ['open4', '>= 0.9.6'],
     ['jeweler', '>= 1.0.0']
    ].each { |i|
      gem.add_dependency(i[0], i[1])
    }
    gem.files = FileList['app_generators/**/*',
                         'wakame_generators/**/*',
                         'contrib/**/*',
                         'lib/**/*.rb',
                         'bin/*',
                         '[A-Z]*',
                         'tasks/**/*',
                         'tests/**/*'].to_a
  end

rescue LoadError
  puts "Jeweler (or a dependency) not available. Install it with: sudo gem install jeweler"
end

require 'rake/testtask'
Rake::TestTask.new(:test) do |test|
  test.libs << 'lib' << 'test'
  test.pattern = 'test/**/*_test.rb'
  test.verbose = true
end

begin
  require 'rcov/rcovtask'
  Rcov::RcovTask.new do |test|
    test.libs << 'test'
    test.pattern = 'test/**/*_test.rb'
    test.verbose = true
  end
rescue LoadError
  task :rcov do
    abort "RCov is not available. In order to run rcov, you must: sudo gem install spicycode-rcov"
  end
end


task :default => :test

require 'rake/rdoctask'
Rake::RDocTask.new do |rdoc|
  if File.exist?('VERSION.yml')
    config = YAML.load(File.read('VERSION.yml'))
    version = "#{config[:major]}.#{config[:minor]}.#{config[:patch]}"
  else
    version = ""
  end

  rdoc.rdoc_dir = 'rdoc'
  rdoc.title = "wakame #{version}"
  rdoc.rdoc_files.include('README*')
  rdoc.rdoc_files.include('lib/**/*.rb')
end

Dir['tasks/**/*.rake'].each { |t| load t }

# task :default => [:spec, :features]
# vim: syntax=Ruby
