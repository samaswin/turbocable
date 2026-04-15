# frozen_string_literal: true

RSpec.describe Turbocable::Client do
  let(:config) { Turbocable::Configuration.new }

  # A stub NatsConnection that records publishes without hitting NATS
  let(:fake_ack) { double("PubAck", stream: "TURBOCABLE", seq: 1) }
  let(:stub_connection) do
    instance_double(Turbocable::NatsConnection, publish: fake_ack)
  end

  subject(:client) { described_class.new(config, connection: stub_connection) }

  # -------------------------------------------------------------------------
  # Stream name validation
  # -------------------------------------------------------------------------
  describe "stream name validation" do
    valid_names = %w[
      chat_room_42
      notifications
      user:session:99
      UPPER_CASE
      mixed-Case_123
      a
      A-Z_a-z-0-9
    ]

    invalid_names = [
      "has.dot",
      "wild*card",
      "greater>than",
      "space here",
      "tab\there",
      "newline\nhere",
      "unicode_ñoño",
      "",
      "has>end",
      "*.star",
    ]

    valid_names.each do |name|
      it "accepts #{name.inspect}" do
        expect { client.broadcast(name, {}) }.not_to raise_error
      end
    end

    invalid_names.each do |name|
      it "rejects #{name.inspect}" do
        expect { client.broadcast(name, {}) }
          .to raise_error(Turbocable::InvalidStreamName)
      end
    end
  end

  # -------------------------------------------------------------------------
  # JSON codec selection and encoding
  # -------------------------------------------------------------------------
  describe "codec selection" do
    it "uses config.default_codec when no codec is specified" do
      config.default_codec = :json
      expect(stub_connection).to receive(:publish) do |_subject, bytes, **|
        parsed = ::JSON.parse(bytes)
        expect(parsed["msg"]).to eq("hello")
        fake_ack
      end
      client.broadcast("stream", {msg: "hello"})
    end

    it "uses the per-call codec override" do
      expect(stub_connection).to receive(:publish) do |_subject, bytes, **|
        parsed = ::JSON.parse(bytes)
        expect(parsed["x"]).to eq(1)
        fake_ack
      end
      client.broadcast("stream", {x: 1}, codec: :json)
    end

    it "raises ConfigurationError for unknown codec name" do
      expect { client.broadcast("stream", {}, codec: :nonexistent) }
        .to raise_error(Turbocable::ConfigurationError, /nonexistent/)
    end
  end

  # -------------------------------------------------------------------------
  # Subject construction
  # -------------------------------------------------------------------------
  describe "subject construction" do
    it "builds the subject as '<prefix>.<stream_name>'" do
      config.subject_prefix = "TURBOCABLE"
      expect(stub_connection).to receive(:publish).with(
        "TURBOCABLE.chat_room_99",
        anything,
        timeout: anything
      ).and_return(fake_ack)
      client.broadcast("chat_room_99", {})
    end
  end

  # -------------------------------------------------------------------------
  # Payload size enforcement
  # -------------------------------------------------------------------------
  describe "payload size enforcement" do
    it "raises PayloadTooLargeError when encoded bytes exceed max_payload_bytes" do
      config.max_payload_bytes = 10
      expect { client.broadcast("stream", {data: "x" * 100}) }
        .to raise_error(Turbocable::PayloadTooLargeError) do |e|
          expect(e.limit).to eq(10)
          expect(e.byte_size).to be > 10
        end
    end

    it "does not call NATS when payload is too large" do
      config.max_payload_bytes = 5
      expect(stub_connection).not_to receive(:publish)
      expect { client.broadcast("s", {data: "big" * 10}) }.to raise_error(Turbocable::PayloadTooLargeError)
    end

    it "allows payloads exactly at the limit" do
      bytes = described_class::STREAM_NAME_PATTERN  # just to get a constant reference
      payload = {m: "x"}
      encoded = Turbocable::Codecs::JSON.encode(payload)
      config.max_payload_bytes = encoded.bytesize

      expect(stub_connection).to receive(:publish).and_return(fake_ack)
      expect { client.broadcast("stream", payload) }.not_to raise_error
    end
  end

  # -------------------------------------------------------------------------
  # Return value
  # -------------------------------------------------------------------------
  describe "return value" do
    it "returns the JetStream ack from NatsConnection" do
      result = client.broadcast("stream", {})
      expect(result).to be(fake_ack)
    end
  end

  # -------------------------------------------------------------------------
  # Retry behavior
  # -------------------------------------------------------------------------
  describe "retry on transient NATS errors" do
    before do
      # Silence warn logging during retry specs
      config.logger = Logger.new(File::NULL)
    end

    it "retries up to max_retries times on NATS::IO::Timeout" do
      config.max_retries = 2

      call_count = 0
      allow(stub_connection).to receive(:publish) do
        call_count += 1
        raise NATS::IO::Timeout if call_count <= 2

        fake_ack
      end

      # Sleep is mocked to keep tests fast
      allow(client).to receive(:sleep)

      result = client.broadcast("stream", {})
      expect(result).to be(fake_ack)
      expect(call_count).to eq(3)
    end

    it "raises PublishError after exhausting retries" do
      config.max_retries = 1
      allow(stub_connection).to receive(:publish).and_raise(NATS::IO::Timeout)
      allow(client).to receive(:sleep)

      expect { client.broadcast("stream", {}) }
        .to raise_error(Turbocable::PublishError) do |e|
          expect(e.attempts).to eq(2)  # 1 initial + 1 retry
          expect(e.subject).to eq("TURBOCABLE.stream")
        end
    end

    it "does not retry on non-transient errors" do
      call_count = 0
      allow(stub_connection).to receive(:publish) do
        call_count += 1
        raise Turbocable::PublishError.new("no stream", subject: "TURBOCABLE.s", attempts: 1)
      end

      expect { client.broadcast("s", {}) }.to raise_error(Turbocable::PublishError)
      expect(call_count).to eq(1)
    end
  end

  # -------------------------------------------------------------------------
  # Serialization errors
  # -------------------------------------------------------------------------
  describe "serialization errors" do
    it "raises SerializationError for unencodable payload" do
      expect { client.broadcast("stream", StringIO.new("x")) }
        .to raise_error(Turbocable::SerializationError) do |e|
          expect(e.codec_name).to eq(:json)
        end
    end
  end
end
