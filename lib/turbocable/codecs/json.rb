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

      # Serializes +payload+ to a JSON string (encoded as UTF-8 bytes).
      #
      # @param payload [Object] any JSON-serializable value (Hash, Array, etc.)
      # @return [String] UTF-8-encoded JSON bytes
      # @raise [Turbocable::SerializationError] if the payload cannot be serialized
      def self.encode(payload)
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
