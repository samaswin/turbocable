# frozen_string_literal: true

require "json"

module Turbocable
  module Codecs
    # JSON codec — the default serialization format.
    #
    # Encodes payload hashes (and other JSON-serializable values) to a UTF-8
    # JSON string. The encoding is compatible with the +actioncable-v1-json+
    # WebSocket sub-protocol that +turbocable-server+ supports.
    #
    # The server does *not* enforce a content-type header in the NATS payload;
    # it tries JSON first then MessagePack. The +.content_type+ value here is
    # informational only and matches the WebSocket sub-protocol name so that
    # routing and test assertions can reference a stable constant.
    module JSON
      # @return [String] the WebSocket sub-protocol name for this codec
      def self.content_type
        "actioncable-v1-json"
      end

      # JSON-serializable primitive types. Values whose class is not one of
      # these (or a subclass) are rejected before +JSON.generate+ is called,
      # because newer versions of the +json+ gem silently call +#to_s+ on
      # unknown types rather than raising.
      PRIMITIVE_TYPES = [Hash, Array, String, Integer, Float, TrueClass, FalseClass, NilClass, Symbol].freeze
      private_constant :PRIMITIVE_TYPES

      # Serializes +payload+ to a JSON string (encoded as UTF-8 bytes).
      #
      # @param payload [Object] any JSON-serializable value (Hash, Array, etc.)
      # @return [String] UTF-8-encoded JSON bytes
      # @raise [Turbocable::SerializationError] if the payload cannot be serialized
      def self.encode(payload)
        unless PRIMITIVE_TYPES.any? { |t| payload.is_a?(t) }
          raise Turbocable::SerializationError.new(
            "JSON codec cannot encode #{payload.class}: not a JSON-serializable type. " \
            "Use a Hash, Array, String, Numeric, Boolean, or nil.",
            codec_name: :json,
            payload_class: payload.class
          )
        end
        ::JSON.generate(payload)
      rescue ::JSON::GeneratorError, ::TypeError => e
        raise Turbocable::SerializationError.new(
          "JSON codec failed to encode #{payload.class}: #{e.message}",
          codec_name: :json,
          payload_class: payload.class
        )
      end

      # Deserializes a JSON string back to a Ruby value.
      # Intended for testing and round-trip specs; production subscribers are
      # WebSocket clients, not this gem.
      #
      # @param bytes [String] JSON-encoded bytes
      # @return [Object]
      def self.decode(bytes)
        ::JSON.parse(bytes, symbolize_names: false)
      end
    end
  end
end
