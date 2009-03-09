require 'uri/generic'

module URI
  class AMQP < Generic
    COMPONENT = [
      :scheme,
      :userinfo, :host, :port,
      :path
    ].freeze

    alias :vhost :path
  end

  @@schemes['AMQP'] = AMQP
end
