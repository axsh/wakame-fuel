
require 'pathname'
WAKAME_ROOT = Pathname.new((ENV['WAKAME_ROOT'] || "#{File.dirname(__FILE__)}/..").dup).realpath unless defined?(WAKAME_ROOT)

module Wakame
  module Bootstrap
    class << self
      def boot_master!
        boot!(:process_master)
      end
      def boot_agent!
        boot!(:process_agent)
      end

      def boot!(method=:process)
        unless booted?
          run_bootstrap
          Wakame::Initializer.run(method)
        end
      end

      def booted?
        #defined?(Wakame::Initializer)
        !@bootclass.nil?
      end

      def boot_type
        @bootclass.class
      end

      def run_bootstrap
        @bootclass = (framework_bundled? ? VendorBoot : GemBoot).new
        @bootclass.run
      end

      def framework_bundled?
        File.exists?("#{WAKAME_ROOT}/vendor/wakame")
      end
    end

    class Boot
      def run
        load_initializer
      end

      def load_initializer
      end
    end

    class VendorBoot < Boot
      def load_initializer
        require "#{WAKAME_ROOT}/vendor/wakame/lib/wakame/initializer"
        require "#{WAKAME_ROOT}/vendor/wakame/lib/wakame/configuration"
      end
    end

    class GemBoot < Boot
      def load_initializer
        load_rubygems
        gem 'wakame'
        require 'wakame/initializer'
        require 'wakame/configuration'
      end


      def load_rubygems
        require 'rubygems'
        unless rubygems_version >= '1.3.0'
          $stderr.puts "Rails requires RubyGems >= #{min_version} (you have #{rubygems_version}). Please `gem update --system` and try again."
          exit 1
        end

      rescue LoadError
        $stderr.puts "Rails requires RubyGems >= #{min_version}. Please install RubyGems and try again: http://rubygems.rubyforge.org"
        exit 1
      end


    end

  end
end
