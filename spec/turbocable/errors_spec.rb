# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass
RSpec.describe "Turbocable error classes" do
  describe Turbocable::Error do
    it "inherits from StandardError" do
      expect(described_class.superclass).to be(StandardError)
    end
  end

  describe Turbocable::ConfigurationError do
    it "inherits from Turbocable::Error" do
      expect(described_class.superclass).to be(Turbocable::Error)
    end

    it "can be raised with a message" do
      expect { raise described_class, "bad config" }
        .to raise_error(described_class, "bad config")
    end
  end

  describe Turbocable::InvalidStreamName do
    it "inherits from Turbocable::Error" do
      expect(described_class.superclass).to be(Turbocable::Error)
    end
  end

  describe Turbocable::SerializationError do
    subject(:error) do
      described_class.new("boom", codec_name: :json, payload_class: Symbol)
    end

    it "inherits from Turbocable::Error" do
      expect(described_class.superclass).to be(Turbocable::Error)
    end

    it "exposes codec_name" do
      expect(error.codec_name).to eq(:json)
    end

    it "exposes payload_class" do
      expect(error.payload_class).to be(Symbol)
    end

    it "carries the message" do
      expect(error.message).to eq("boom")
    end
  end

  describe Turbocable::PublishError do
    subject(:error) do
      described_class.new("give up", subject: "TURBOCABLE.foo", attempts: 3, cause: cause)
    end

    let(:cause) { RuntimeError.new("nats exploded") }

    it "inherits from Turbocable::Error" do
      expect(described_class.superclass).to be(Turbocable::Error)
    end

    it "exposes subject" do
      expect(error.subject).to eq("TURBOCABLE.foo")
    end

    it "exposes attempts" do
      expect(error.attempts).to eq(3)
    end

    it "exposes cause" do
      expect(error.cause).to be(cause)
    end
  end

  describe Turbocable::PayloadTooLargeError do
    subject(:error) { described_class.new(byte_size: 2_000_000, limit: 1_000_000) }

    it "inherits from Turbocable::Error" do
      expect(described_class.superclass).to be(Turbocable::Error)
    end

    it "exposes byte_size" do
      expect(error.byte_size).to eq(2_000_000)
    end

    it "exposes limit" do
      expect(error.limit).to eq(1_000_000)
    end

    it "generates a descriptive message" do
      expect(error.message).to match(/2000000.*bytes.*1000000/)
    end
  end

  describe "rescue hierarchy" do
    it "rescues all errors via Turbocable::Error" do
      [
        Turbocable::ConfigurationError,
        Turbocable::InvalidStreamName,
        Turbocable::PublishError.new("x", subject: "s", attempts: 1),
        Turbocable::PayloadTooLargeError.new(byte_size: 1, limit: 0),
        Turbocable::SerializationError.new("x", codec_name: :json, payload_class: String)
      ].each do |error|
        expect { raise error }.to raise_error(Turbocable::Error)
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass
