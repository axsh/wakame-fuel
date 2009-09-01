require 'uri/generic'

module URI
  class AMQP < Generic
    COMPONENT = [
      :scheme,
      :userinfo, :host, :port,
      :path
    ].freeze

    DEFAULT_PORT=5672

    def self.build(args)
      tmp = Util::make_components_hash(self, args)
      return super(tmp)
    end

    alias :vhost :path
    alias :vhost= :path=
  end

  @@schemes['AMQP'] = AMQP
end
