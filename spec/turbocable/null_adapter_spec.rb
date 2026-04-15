# frozen_string_literal: true

RSpec.describe Turbocable::NullAdapter do
  subject(:adapter) { described_class.new }

  before { described_class.reset! }
  after { described_class.reset! }

  # -------------------------------------------------------------------------
  # publish — records into the class-level buffer
  # -------------------------------------------------------------------------
  describe "#publish" do
    it "returns a NullAck" do
      result = adapter.publish("TURBOCABLE.stream", "bytes", timeout: 1.0)
      expect(result).to be_a(described_class::NullAck)
    end

    it "records the subject in broadcasts" do
      adapter.publish("TURBOCABLE.chat_room_42", "payload", timeout: 1.0)
      expect(described_class.broadcasts.first[:subject]).to eq("TURBOCABLE.chat_room_42")
    end

    it "records the raw payload bytes" do
      adapter.publish("TURBOCABLE.s", "raw_bytes", timeout: 1.0)
      expect(described_class.broadcasts.first[:payload]).to eq("raw_bytes")
    end

    it "records the :at timestamp as a Time" do
      before_publish = Time.now
      adapter.publish("TURBOCABLE.s", "b", timeout: 1.0)
      after_publish = Time.now
      ts = described_class.broadcasts.first[:at]
      expect(ts).to be_a(Time)
      expect(ts).to be >= before_publish
      expect(ts).to be <= after_publish
    end

    it "sets :codec to nil (codec is resolved upstream in Client)" do
      adapter.publish("TURBOCABLE.s", "b", timeout: 1.0)
      expect(described_class.broadcasts.first[:codec]).to be_nil
    end

    it "accumulates multiple publishes" do
      3.times { |i| adapter.publish("TURBOCABLE.s#{i}", "b", timeout: 1.0) }
      expect(described_class.broadcasts.size).to eq(3)
    end
  end

  # -------------------------------------------------------------------------
  # ring buffer — evicts oldest when full
  # -------------------------------------------------------------------------
  describe "ring buffer eviction" do
    it "evicts the oldest entry once the buffer is full" do
      small_adapter = described_class.new(buffer_size: 3)
      4.times { |i| small_adapter.publish("TURBOCABLE.s#{i}", "b", timeout: 1.0) }

      subjects = described_class.broadcasts.map { |b| b[:subject] }
      expect(subjects).not_to include("TURBOCABLE.s0")
      expect(subjects).to include("TURBOCABLE.s1", "TURBOCABLE.s2", "TURBOCABLE.s3")
    end

    it "never exceeds the buffer size" do
      small_adapter = described_class.new(buffer_size: 5)
      10.times { small_adapter.publish("TURBOCABLE.s", "b", timeout: 1.0) }
      expect(described_class.broadcasts.size).to eq(5)
    end
  end

  # -------------------------------------------------------------------------
  # reset! — clears the buffer
  # -------------------------------------------------------------------------
  describe ".reset!" do
    it "clears all recorded broadcasts" do
      adapter.publish("TURBOCABLE.s", "b", timeout: 1.0)
      described_class.reset!
      expect(described_class.broadcasts).to be_empty
    end
  end

  # -------------------------------------------------------------------------
  # broadcasts — returns a snapshot
  # -------------------------------------------------------------------------
  describe ".broadcasts" do
    it "returns a duplicate so mutations do not affect the buffer" do
      adapter.publish("TURBOCABLE.s", "b", timeout: 1.0)
      snapshot = described_class.broadcasts
      snapshot.clear
      expect(described_class.broadcasts.size).to eq(1)
    end
  end

  # -------------------------------------------------------------------------
  # ping — always healthy
  # -------------------------------------------------------------------------
  describe "#ping" do
    it "returns true" do
      expect(adapter.ping).to be true
    end

    it "accepts an explicit timeout argument" do
      expect(adapter.ping(timeout: 0.1)).to be true
    end
  end

  # -------------------------------------------------------------------------
  # key_value — not supported
  # -------------------------------------------------------------------------
  describe "#key_value" do
    it "raises NotImplementedError" do
      expect { adapter.key_value("TC_PUBKEYS") }
        .to raise_error(NotImplementedError, /NullAdapter/)
    end
  end

  # -------------------------------------------------------------------------
  # close — no-op
  # -------------------------------------------------------------------------
  describe "#close" do
    it "does not raise" do
      expect { adapter.close }.not_to raise_error
    end
  end

  # -------------------------------------------------------------------------
  # Thread safety
  # -------------------------------------------------------------------------
  describe "thread safety" do
    it "handles concurrent publishes without data loss or corruption" do
      threads = 8.times.map do |i|
        Thread.new { adapter.publish("TURBOCABLE.t#{i}", "bytes_#{i}", timeout: 1.0) }
      end
      threads.each(&:join)

      expect(described_class.broadcasts.size).to eq(8)
    end
  end

  # -------------------------------------------------------------------------
  # Integration with Client (adapter: :null wiring)
  # -------------------------------------------------------------------------
  describe "wiring through Client" do
    it "is used when config.adapter = :null" do
      config = Turbocable::Configuration.new
      config.adapter = :null
      client = Turbocable::Client.new(config)

      client.broadcast("stream", {msg: "hi"})

      expect(described_class.broadcasts.size).to eq(1)
      expect(described_class.broadcasts.first[:subject]).to eq("TURBOCABLE.stream")
    end

    it "does not touch NATS when adapter is :null" do
      config = Turbocable::Configuration.new
      config.adapter = :null
      client = Turbocable::Client.new(config)

      allow(Turbocable::NatsConnection).to receive(:new)
      client.broadcast("stream", {})
      expect(Turbocable::NatsConnection).not_to have_received(:new)
    end
  end

  # -------------------------------------------------------------------------
  # NullAck struct
  # -------------------------------------------------------------------------
  describe "NullAck" do
    subject(:ack) { described_class::NullAck.new }

    it "has stream 'TURBOCABLE'" do
      expect(ack.stream).to eq("TURBOCABLE")
    end

    it "has seq 0" do
      expect(ack.seq).to eq(0)
    end

    it "has duplicate false" do
      expect(ack.duplicate).to be false
    end
  end
end
