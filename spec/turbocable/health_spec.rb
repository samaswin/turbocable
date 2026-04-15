# frozen_string_literal: true

RSpec.describe "Turbocable health check" do
  # -------------------------------------------------------------------------
  # healthy? — delegates to Client#healthy? which delegates to adapter#ping
  # -------------------------------------------------------------------------
  describe "Turbocable.healthy?" do
    context "when the adapter returns true from ping" do
      it "returns true" do
        stub_adapter = instance_double(Turbocable::NullAdapter)
        allow(stub_adapter).to receive(:ping).and_return(true)
        allow(stub_adapter).to receive(:close)
        allow(Turbocable::NullAdapter).to receive(:new).and_return(stub_adapter)

        Turbocable.configure { |c| c.adapter = :null }

        expect(Turbocable.healthy?).to be true
      end
    end

    context "when the adapter raises a network error" do
      it "returns false and does not propagate the error" do
        stub_conn = instance_double(Turbocable::NatsConnection)
        allow(stub_conn).to receive(:ping).and_raise(StandardError, "connection refused")
        allow(stub_conn).to receive(:close)

        client = Turbocable::Client.new(Turbocable.config, connection: stub_conn)
        Turbocable.instance_variable_set(:@client, client)

        # Should be false, must not raise
        expect { Turbocable.healthy? }.not_to raise_error
        expect(Turbocable.healthy?).to be false
      end
    end

    context "when configuration is invalid" do
      it "raises ConfigurationError (not swallowed)" do
        Turbocable.configure do |c|
          c.nats_creds_file = "/some/path.creds"
          c.nats_token = "tok"  # mutually exclusive — triggers ConfigurationError
        end

        stub_conn = instance_double(Turbocable::NatsConnection)
        allow(stub_conn).to receive(:ping).and_raise(Turbocable::ConfigurationError, "bad config")
        allow(stub_conn).to receive(:close)

        client = Turbocable::Client.new(Turbocable.config, connection: stub_conn)
        Turbocable.instance_variable_set(:@client, client)

        expect { Turbocable.healthy? }.to raise_error(Turbocable::ConfigurationError)
      end
    end

    context "with the null adapter" do
      it "always returns true without touching NATS" do
        Turbocable.configure { |c| c.adapter = :null }
        expect(Turbocable::NatsConnection).not_to receive(:new)
        expect(Turbocable.healthy?).to be true
      end
    end
  end

  # -------------------------------------------------------------------------
  # healthcheck! — raises HealthCheckError on failure
  # -------------------------------------------------------------------------
  describe "Turbocable.healthcheck!" do
    context "when healthy? returns true" do
      it "returns true" do
        Turbocable.configure { |c| c.adapter = :null }
        expect(Turbocable.healthcheck!).to be true
      end
    end

    context "when healthy? returns false" do
      it "raises HealthCheckError with an actionable message" do
        stub_conn = instance_double(Turbocable::NatsConnection)
        allow(stub_conn).to receive(:ping).and_raise(StandardError, "unreachable")
        allow(stub_conn).to receive(:close)

        client = Turbocable::Client.new(Turbocable.config, connection: stub_conn)
        Turbocable.instance_variable_set(:@client, client)

        expect { Turbocable.healthcheck! }
          .to raise_error(Turbocable::HealthCheckError) do |e|
            expect(e.message).to include("NATS is unreachable")
            expect(e.message).to include(Turbocable.config.nats_url)
          end
      end
    end
  end

  # -------------------------------------------------------------------------
  # Client#healthy? — unit-level
  # -------------------------------------------------------------------------
  describe Turbocable::Client do
    let(:config) { Turbocable::Configuration.new }

    describe "#healthy?" do
      it "returns true when adapter ping succeeds" do
        stub_conn = instance_double(Turbocable::NatsConnection, ping: true)
        client = described_class.new(config, connection: stub_conn)
        expect(client.healthy?).to be true
      end

      it "returns false when adapter ping raises a network error" do
        stub_conn = instance_double(Turbocable::NatsConnection)
        allow(stub_conn).to receive(:ping).and_raise(NATS::IO::Timeout)
        config.logger = Logger.new(File::NULL)

        client = described_class.new(config, connection: stub_conn)
        expect(client.healthy?).to be false
      end

      it "passes publish_timeout to ping" do
        config.publish_timeout = 0.5
        stub_conn = instance_double(Turbocable::NatsConnection)
        expect(stub_conn).to receive(:ping).with(timeout: 0.5).and_return(true)

        client = described_class.new(config, connection: stub_conn)
        client.healthy?
      end

      it "re-raises ConfigurationError without swallowing" do
        stub_conn = instance_double(Turbocable::NatsConnection)
        allow(stub_conn).to receive(:ping).and_raise(Turbocable::ConfigurationError, "bad")

        client = described_class.new(config, connection: stub_conn)
        expect { client.healthy? }.to raise_error(Turbocable::ConfigurationError)
      end

      it "logs a warning when ping fails" do
        log_io = StringIO.new
        config.logger = Logger.new(log_io, level: Logger::DEBUG)

        stub_conn = instance_double(Turbocable::NatsConnection)
        allow(stub_conn).to receive(:ping).and_raise(StandardError, "timed out")

        client = described_class.new(config, connection: stub_conn)
        client.healthy?

        expect(log_io.string).to include("[Turbocable] Health check failed")
      end
    end
  end
end
