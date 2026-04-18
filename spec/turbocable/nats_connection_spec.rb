# frozen_string_literal: true

require "spec_helper"

RSpec.describe Turbocable::NatsConnection do
  describe "#key_value" do
    let(:config) do
      Turbocable::Configuration.new.tap do |c|
        c.nats_url = "nats://127.0.0.1:4222"
        c.logger = Logger.new(File::NULL)
      end
    end

    let(:js) { instance_double(NATS::JetStream::Context) }
    # Minimal stand-in for NATS::IO::Client — only +closed?+ is read by
    # +connected_in_current_process?+.
    let(:nc) do
      Class.new do
        def closed?
          false
        end
      end.new
    end
    let(:connection) { described_class.new(config) }

    before do
      # Satisfy +connected_in_current_process?+ so +ensure_connected!+ returns
      # without opening a socket (stubbing private methods breaks under
      # +verify_partial_doubles+).
      connection.instance_variable_set(:@nc, nc)
      connection.instance_variable_set(:@pid, Process.pid)
      connection.instance_variable_set(:@js, js)
    end

    it "returns the handle when the bucket already exists" do
      kv = instance_double(NATS::KeyValue)
      allow(js).to receive(:key_value).with("TC_PUBKEYS").and_return(kv)

      expect(connection.key_value("TC_PUBKEYS")).to eq(kv)
      expect(js).not_to have_received(:create_key_value)
    end

    it "creates the bucket when nats-pure raises BucketNotFoundError" do
      kv = instance_double(NATS::KeyValue)
      allow(js).to receive(:key_value).with("TC_PUBKEYS")
        .and_raise(NATS::KeyValue::BucketNotFoundError.new("nats: bucket not found"))
      allow(js).to receive(:create_key_value).with(bucket: "TC_PUBKEYS", history: 1).and_return(kv)

      expect(connection.key_value("TC_PUBKEYS")).to eq(kv)
    end
  end
end
