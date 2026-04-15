# frozen_string_literal: true

# Integration spec — requires a running compose stack.
#
# Run with:
#   docker compose up -d nats turbocable-server
#   INTEGRATION=true bundle exec rspec spec/integration
#
# Or via the CI compose service which sets INTEGRATION=true automatically.
#
# Every example waits on GET http://turbocable-server:9292/health returning 200
# before touching NATS. This makes server boot races visible as setup failures
# rather than assertion flakes.

require "net/http"
require "uri"
require "nats/client"

INTEGRATION_ENABLED = ENV["INTEGRATION"] == "true" unless defined?(INTEGRATION_ENABLED)

PUBLISH_NATS_URL = ENV.fetch("TURBOCABLE_NATS_URL", "nats://localhost:4222")
PUBLISH_SERVER_HEALTH_URL = ENV.fetch("TURBOCABLE_SERVER_HEALTH_URL", "http://localhost:9292/health")
PUBLISH_HEALTH_TIMEOUT_SECS = Integer(ENV.fetch("HEALTH_TIMEOUT_SECS", "30"))

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleDescribes
RSpec.describe "Core publish path (integration)", if: INTEGRATION_ENABLED do
  # -------------------------------------------------------------------------
  # Topology helpers
  # -------------------------------------------------------------------------

  def wait_for_server_health!
    deadline = Time.now + PUBLISH_HEALTH_TIMEOUT_SECS
    uri = URI(PUBLISH_SERVER_HEALTH_URL)
    loop do
      begin
        response = Net::HTTP.get_response(uri)
        return if response.is_a?(Net::HTTPOK)
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError
        # server not ready yet
      end
      raise "turbocable-server did not become healthy within #{PUBLISH_HEALTH_TIMEOUT_SECS}s" if Time.now > deadline

      sleep 1
    end
  end

  # -------------------------------------------------------------------------
  # Suite-level setup: verify topology once before all examples run
  # -------------------------------------------------------------------------
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    wait_for_server_health!
  end

  # Each example gets a fresh Turbocable configuration pointing at the test
  # NATS instance with no auth (the default compose service).
  around do |example|
    Turbocable.reset!
    Turbocable.configure do |c|
      c.nats_url = PUBLISH_NATS_URL
      c.default_codec = :json
      c.publish_timeout = 5.0
      c.max_retries = 1
      c.logger = Logger.new(File::NULL)
    end
    example.run
    Turbocable.reset!
  end

  # -------------------------------------------------------------------------
  # Basic publish + JetStream receipt
  # -------------------------------------------------------------------------
  describe "Turbocable.broadcast" do
    it "publishes a JSON message visible on the TURBOCABLE JetStream stream" do # rubocop:disable RSpec/ExampleLength
      stream = "integration_test_#{SecureRandom.hex(4)}"
      payload = {text: "hello from integration test", at: Time.now.iso8601}

      # Subscribe to the subject *before* publishing so we can pull the message
      received = nil
      nc = NATS::IO::Client.new
      nc.connect(PUBLISH_NATS_URL)

      js = nc.jetstream
      subject = "TURBOCABLE.#{stream}"

      # Publish via the gem
      ack = Turbocable.broadcast(stream, payload)
      expect(ack).to respond_to(:stream, :seq)
      expect(ack.stream).to eq("TURBOCABLE")
      expect(ack.seq).to be_a(Integer)

      # Pull the message back from JetStream to confirm it landed
      consumer_name = "test_consumer_#{SecureRandom.hex(4)}"
      js.subscribe(subject, durable: consumer_name, manual_ack: true) do |msg|
        received = msg
        msg.ack
      end

      deadline = Time.now + 5
      sleep 0.1 until received || Time.now > deadline

      expect(received).not_to be_nil, "Expected a message on #{subject} within 5 s"

      parsed = ::JSON.parse(received.data)
      expect(parsed["text"]).to eq("hello from integration test")
    ensure
      nc&.close
    end

    it "returns a JetStream ack with the TURBOCABLE stream name" do
      ack = Turbocable.broadcast("ack_test_#{SecureRandom.hex(4)}", {x: 1})
      expect(ack.stream).to eq("TURBOCABLE")
    end

    it "increments the sequence number on successive publishes" do
      stream = "seq_test_#{SecureRandom.hex(4)}"
      ack1 = Turbocable.broadcast(stream, {n: 1})
      ack2 = Turbocable.broadcast(stream, {n: 2})
      expect(ack2.seq).to be > ack1.seq
    end
  end

  # -------------------------------------------------------------------------
  # Server health endpoint reachability
  # -------------------------------------------------------------------------
  describe "turbocable-server /health" do
    it "returns 200 with a JSON body containing status and version" do
      response = Net::HTTP.get_response(URI(SERVER_HEALTH_URL))
      expect(response.code).to eq("200")

      body = ::JSON.parse(response.body)
      expect(body).to include("status")
      expect(body).to include("version")
      expect(body).to include("nats_connected")
    end
  end

  # -------------------------------------------------------------------------
  # Error cases
  # -------------------------------------------------------------------------
  describe "when the stream does not exist" do
    # This test temporarily points the gem at a non-existent NATS server to
    # simulate a missing stream error path. Skipped if the NATS port check
    # times out to avoid false failures.
    it "raises PublishError with an actionable message when NATS is unreachable" do
      Turbocable.reset!
      Turbocable.configure do |c|
        c.nats_url = "nats://localhost:14222"  # nothing listening here
        c.publish_timeout = 1.0
        c.max_retries = 0
        c.logger = Logger.new(File::NULL)
      end

      expect { Turbocable.broadcast("unreachable", {}) }
        .to raise_error(Turbocable::PublishError)
    end
  end
end

RSpec.describe "Core publish path (integration)", unless: INTEGRATION_ENABLED do
  it "skipped — set INTEGRATION=true and run against the compose stack to enable"
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleDescribes
