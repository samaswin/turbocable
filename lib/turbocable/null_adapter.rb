# frozen_string_literal: true

module Turbocable
  # A drop-in replacement for +NatsConnection+ that records every publish call
  # in an in-memory ring buffer instead of hitting NATS.
  #
  # == Usage in test suites
  #
  #   # spec_helper.rb / rails_helper.rb
  #   RSpec.configure do |config|
  #     config.around(:each) do |example|
  #       Turbocable.configure { |c| c.adapter = :null }
  #       example.run
  #       Turbocable::NullAdapter.reset!
  #     end
  #   end
  #
  #   # In a spec:
  #   it "broadcasts the payload" do
  #     Turbocable.broadcast("chat_room_42", text: "hello")
  #     recorded = Turbocable::NullAdapter.broadcasts
  #     expect(recorded.size).to eq(1)
  #     expect(recorded.first[:subject]).to eq("TURBOCABLE.chat_room_42")
  #   end
  #
  # == Thread safety
  #
  # All access to the shared ring buffer is serialized through a class-level
  # +Mutex+. Instances of +NullAdapter+ are stateless — they delegate recording
  # to class-level state so that callers can inspect broadcasts without keeping
  # a reference to the adapter instance.
  #
  # == Ring buffer
  #
  # Older entries are evicted once the buffer reaches +MAX_BUFFER+ records.
  # This prevents unbounded memory growth in long-running test suites.
  class NullAdapter
    # Default maximum number of broadcast records kept in memory.
    MAX_BUFFER = 1_000

    @mutex = Mutex.new
    @broadcasts = []

    class << self
      # Returns a snapshot of all recorded broadcasts since the last +reset!+.
      #
      # Each element is a Hash with keys:
      # * +:subject+ — the full NATS subject (e.g. +"TURBOCABLE.chat_room_42"+)
      # * +:payload+ — encoded bytes as published
      # * +:codec+   — always +nil+ at the adapter layer (codec is resolved by
      #   +Client+ before reaching the adapter)
      # * +:at+      — +Time+ of the publish call
      #
      # @return [Array<Hash>]
      def broadcasts
        @mutex.synchronize { @broadcasts.dup }
      end

      # Clears all recorded broadcasts. Call this between test examples to
      # prevent cross-example pollution. Thread-safe.
      #
      # @return [void]
      def reset!
        @mutex.synchronize { @broadcasts.clear }
      end

      # @api private
      def record(subject:, payload:, at:, buffer_size:)
        @mutex.synchronize do
          @broadcasts << {subject: subject, payload: payload, codec: nil, at: at}
          @broadcasts.shift while @broadcasts.size > buffer_size
        end
      end
    end

    # @param buffer_size [Integer] maximum number of records to keep
    def initialize(buffer_size: MAX_BUFFER)
      @buffer_size = buffer_size
    end

    # Records the publish in the class-level ring buffer and returns a fake ack.
    #
    # @param subject [String]
    # @param bytes   [String]
    # @param timeout [Float]  accepted but ignored
    # @return [NullAck]
    def publish(subject, bytes, timeout:)
      self.class.record(subject: subject, payload: bytes, at: Time.now, buffer_size: @buffer_size)
      NullAck.new
    end

    # Always returns +true+ — the null adapter is always "healthy".
    #
    # @param timeout [Float]  accepted but ignored
    # @return [true]
    def ping(timeout: 2.0)
      true
    end

    # Not supported on the null adapter. Raises +NotImplementedError+ so that
    # callers don't silently succeed when running against the null adapter in
    # contexts where KV access is required (e.g. +publish_public_key!+).
    #
    # @raise [NotImplementedError]
    def key_value(*)
      raise NotImplementedError,
        "NullAdapter does not support key_value. " \
        "Use the :nats adapter when you need KV access."
    end

    # No-op. Satisfies the adapter interface so +Turbocable.reset!+ can call
    # +close+ on the adapter without a conditional.
    #
    # @return [void]
    def close
    end

    # Lightweight struct returned by +#publish+ in place of a real
    # +NATS::JetStream::PubAck+.
    NullAck = Struct.new(:stream, :seq, :duplicate) do
      # @param stream    [String]  always +"TURBOCABLE"+
      # @param seq       [Integer] always +0+
      # @param duplicate [Boolean] always +false+
      def initialize(stream: "TURBOCABLE", seq: 0, duplicate: false)
        super(stream, seq, duplicate)
      end
    end
  end
end
