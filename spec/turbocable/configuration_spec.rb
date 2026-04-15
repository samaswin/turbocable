# frozen_string_literal: true

RSpec.describe Turbocable::Configuration do
  subject(:config) { described_class.new }

  # -------------------------------------------------------------------------
  # Defaults
  # -------------------------------------------------------------------------
  describe "defaults" do
    it "defaults nats_url to localhost" do
      expect(config.nats_url).to eq("nats://localhost:4222")
    end

    it "defaults stream_name to TURBOCABLE" do
      expect(config.stream_name).to eq("TURBOCABLE")
    end

    it "defaults subject_prefix to TURBOCABLE" do
      expect(config.subject_prefix).to eq("TURBOCABLE")
    end

    it "defaults default_codec to :json" do
      expect(config.default_codec).to eq(:json)
    end

    it "defaults publish_timeout to 2.0" do
      expect(config.publish_timeout).to eq(2.0)
    end

    it "defaults max_retries to 3" do
      expect(config.max_retries).to eq(3)
    end

    it "defaults max_payload_bytes to 1_000_000" do
      expect(config.max_payload_bytes).to eq(1_000_000)
    end

    it "defaults all auth fields to nil" do
      expect(config.nats_creds_file).to be_nil
      expect(config.nats_user).to be_nil
      expect(config.nats_password).to be_nil
      expect(config.nats_token).to be_nil
    end

    it "defaults nats_tls to false" do
      expect(config.nats_tls).to be(false)
    end

    it "defaults TLS path fields to nil" do
      expect(config.nats_tls_ca_file).to be_nil
      expect(config.nats_tls_cert_file).to be_nil
      expect(config.nats_tls_key_file).to be_nil
    end

    it "provides a Logger-compatible default logger" do
      expect(config.logger).to respond_to(:debug, :info, :warn, :error)
    end
  end

  # -------------------------------------------------------------------------
  # Env var bindings
  # -------------------------------------------------------------------------
  describe "environment variable bindings" do
    around do |example|
      old_env = ENV.to_h.select { |k, _| k.start_with?("TURBOCABLE_") }
      example.run
      old_env.each { |k, v| ENV[k] = v }
      ENV.delete_if { |k, _| k.start_with?("TURBOCABLE_") && !old_env.key?(k) }
    end

    it "reads nats_url from TURBOCABLE_NATS_URL" do
      ENV["TURBOCABLE_NATS_URL"] = "nats://custom:4222"
      expect(described_class.new.nats_url).to eq("nats://custom:4222")
    end

    it "reads nats_token from TURBOCABLE_NATS_AUTH_TOKEN" do
      ENV["TURBOCABLE_NATS_AUTH_TOKEN"] = "s3cr3t"
      expect(described_class.new.nats_token).to eq("s3cr3t")
    end

    it "reads nats_user from TURBOCABLE_NATS_USER" do
      ENV["TURBOCABLE_NATS_USER"] = "alice"
      expect(described_class.new.nats_user).to eq("alice")
    end

    it "reads nats_tls from TURBOCABLE_NATS_TLS" do
      ENV["TURBOCABLE_NATS_TLS"] = "true"
      expect(described_class.new.nats_tls).to be(true)
    end

    it "treats TURBOCABLE_NATS_TLS=1 as true" do
      ENV["TURBOCABLE_NATS_TLS"] = "1"
      expect(described_class.new.nats_tls).to be(true)
    end

    it "treats TURBOCABLE_NATS_TLS=false as false" do
      ENV["TURBOCABLE_NATS_TLS"] = "false"
      expect(described_class.new.nats_tls).to be(false)
    end
  end

  # -------------------------------------------------------------------------
  # Setters
  # -------------------------------------------------------------------------
  describe "attribute writers" do
    it "accepts nats_url assignment" do
      config.nats_url = "nats://prod:4222"
      expect(config.nats_url).to eq("nats://prod:4222")
    end

    it "accepts default_codec assignment" do
      config.default_codec = :msgpack
      expect(config.default_codec).to eq(:msgpack)
    end

    it "accepts publish_timeout assignment" do
      config.publish_timeout = 5.0
      expect(config.publish_timeout).to eq(5.0)
    end

    it "accepts max_retries assignment" do
      config.max_retries = 0
      expect(config.max_retries).to eq(0)
    end

    it "accepts logger assignment" do
      logger = instance_double("Logger", debug: nil, info: nil, warn: nil, error: nil)
      config.logger = logger
      expect(config.logger).to be(logger)
    end
  end

  # -------------------------------------------------------------------------
  # validate! — auth mutual exclusion
  # -------------------------------------------------------------------------
  describe "#validate! auth mutual exclusion" do
    it "passes when no auth is configured" do
      expect { config.validate! }.not_to raise_error
    end

    it "passes with only creds_file set" do
      config.nats_creds_file = "/nonexistent/file.creds"
      # File existence is not checked in validate! for creds_file (only TLS paths)
      expect { config.validate! }.not_to raise_error
    end

    it "passes with only nats_token set" do
      config.nats_token = "tok"
      expect { config.validate! }.not_to raise_error
    end

    it "passes with only nats_user/nats_password set" do
      config.nats_user     = "alice"
      config.nats_password = "pw"
      expect { config.validate! }.not_to raise_error
    end

    it "raises ConfigurationError when creds_file and token are both set" do
      config.nats_creds_file = "/some/file.creds"
      config.nats_token      = "tok"
      expect { config.validate! }.to raise_error(
        Turbocable::ConfigurationError, /mutually exclusive/
      )
    end

    it "raises ConfigurationError when creds_file and user/password are both set" do
      config.nats_creds_file = "/some/file.creds"
      config.nats_user       = "alice"
      expect { config.validate! }.to raise_error(Turbocable::ConfigurationError)
    end
  end

  # -------------------------------------------------------------------------
  # validate! — TLS path existence
  # -------------------------------------------------------------------------
  describe "#validate! TLS path validation" do
    it "raises ConfigurationError for nats_tls_ca_file pointing to missing file" do
      config.nats_tls_ca_file = "/nonexistent/ca.pem"
      expect { config.validate! }.to raise_error(
        Turbocable::ConfigurationError, /nats_tls_ca_file.*does not exist/
      )
    end

    it "raises ConfigurationError when cert is set without key" do
      ca = Tempfile.new("ca.pem")
      cert = Tempfile.new("cert.pem")
      config.nats_tls_ca_file   = ca.path
      config.nats_tls_cert_file = cert.path
      # key intentionally omitted

      expect { config.validate! }.to raise_error(
        Turbocable::ConfigurationError, /nats_tls_cert_file requires nats_tls_key_file/
      )
    ensure
      ca.close!
      cert.close!
    end

    it "raises ConfigurationError when key is set without cert" do
      key = Tempfile.new("key.pem")
      config.nats_tls_key_file = key.path

      expect { config.validate! }.to raise_error(
        Turbocable::ConfigurationError, /nats_tls_key_file requires nats_tls_cert_file/
      )
    ensure
      key.close!
    end

    it "passes when cert and key both point to existing files" do
      cert = Tempfile.new("cert.pem")
      key  = Tempfile.new("key.pem")
      config.nats_tls_cert_file = cert.path
      config.nats_tls_key_file  = key.path

      expect { config.validate! }.not_to raise_error
    ensure
      cert.close!
      key.close!
    end
  end
end
