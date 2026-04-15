# frozen_string_literal: true

require_relative "codecs/json"

module Turbocable
  # Registry for payload codecs. Each codec exposes:
  #
  #   .encode(payload) -> String (bytes)
  #   .decode(bytes)   -> Object  (for tests / round-trips)
  #   .content_type    -> String  (WebSocket sub-protocol name, informational)
  #
  # Built-in codecs: +:json+ (always available), +:msgpack+ (Phase 2, requires
  # the +msgpack+ gem).
  #
  # @example Fetch the JSON codec
  #   codec = Turbocable::Codecs.fetch(:json)
  #   bytes = codec.encode({ text: "hello" })
  module Codecs
    REGISTRY = {
      json: Codecs::JSON
    }.freeze
    private_constant :REGISTRY

    # Returns the codec module for +name+.
    #
    # @param name [Symbol, String]
    # @return [Module] a codec module with +.encode+, +.decode+, +.content_type+
    # @raise [Turbocable::ConfigurationError] if +name+ is not registered
    def self.fetch(name)
      key = name.to_sym
      REGISTRY.fetch(key) do
        raise ConfigurationError,
          "Unknown codec #{key.inspect}. " \
          "Available: #{REGISTRY.keys.map(&:inspect).join(", ")}. " \
          "(:msgpack is added in Phase 2 — ensure the msgpack gem is installed " \
          "and Turbocable::Codecs::MsgPack is registered.)"
      end
    end

    # @return [Array<Symbol>] codec names currently registered
    def self.registered
      REGISTRY.keys
    end
  end
end
