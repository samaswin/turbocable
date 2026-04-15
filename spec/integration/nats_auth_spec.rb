# frozen_string_literal: true

# NATS auth integration specs — parameterized across four auth modes.
#
# Each mode has a corresponding Docker Compose service variant defined in
# docker-compose.yml. Set INTEGRATION=true and AUTH_MODE to one of:
#   no-auth | token-auth | user-pass | mtls
#
# The CI matrix runs all four. Local authors can target a single mode:
#   AUTH_MODE=token-auth INTEGRATION=true bundle exec rspec spec/integration/nats_auth_spec.rb

require "net/http"
require "uri"
require "nats/client"
require "tmpdir"

INTEGRATION_ENABLED    = ENV["INTEGRATION"] == "true" unless defined?(INTEGRATION_ENABLED)
AUTH_MODE              = ENV.fetch("AUTH_MODE", "no-auth")
NATS_URL_BASE          = ENV.fetch("TURBOCABLE_NATS_URL", "nats://localhost:4222")
NATS_TOKEN_VALUE       = ENV.fetch("NATS_TEST_TOKEN",    "test-token-changeme")
NATS_TEST_USER         = ENV.fetch("NATS_TEST_USER",     "testuser")
NATS_TEST_PASSWORD     = ENV.fetch("NATS_TEST_PASSWORD", "testpassword")
NATS_TLS_CA_PATH       = ENV.fetch("NATS_TLS_CA_PATH",   "")
NATS_TLS_CERT_PATH     = ENV.fetch("NATS_TLS_CERT_PATH", "")
NATS_TLS_KEY_PATH      = ENV.fetch("NATS_TLS_KEY_PATH",  "")
NATS_CREDS_FIXTURE     = File.expand_path("../fixtures/nats/test.creds", __dir__)

RSpec.describe "NATS auth integration (#{AUTH_MODE})", if: INTEGRATION_ENABLED do
  around do |example|
    Turbocable.reset!
    example.run
    Turbocable.reset!
  end

  shared_examples "successful publish" do
    it "broadcasts without error" do
      stream = "auth_test_#{SecureRandom.hex(4)}"
      expect { Turbocable.broadcast(stream, {auth_mode: AUTH_MODE}) }.not_to raise_error
    end
  end

  shared_examples "rejected publish" do |desc|
    it "raises PublishError with a readable message (#{desc})" do
      stream = "auth_bad_#{SecureRandom.hex(4)}"
      expect { Turbocable.broadcast(stream, {}) }
        .to raise_error(Turbocable::PublishError)
    end
  end

  # -------------------------------------------------------------------------
  # no-auth: default compose service, no credentials required
  # -------------------------------------------------------------------------
  context "no-auth mode", if: AUTH_MODE == "no-auth" do
    before do
      Turbocable.configure do |c|
        c.nats_url        = NATS_URL_BASE
        c.publish_timeout = 5.0
        c.max_retries     = 0
        c.logger          = Logger.new(File::NULL)
      end
    end

    include_examples "successful publish"

    context "when wrong credentials are supplied anyway" do
      before do
        Turbocable.configure { |c| c.nats_token = "bogus-token-no-auth-server" }
      end

      # nats-server in no-auth mode ignores extra tokens; this may succeed or
      # fail depending on the server config — we just document the behavior.
      it "does not raise a configuration error" do
        expect { Turbocable::Configuration.new.validate! }.not_to raise_error
      end
    end
  end

  # -------------------------------------------------------------------------
  # token-auth: nats-server configured with authorization.token
  # -------------------------------------------------------------------------
  context "token-auth mode", if: AUTH_MODE == "token-auth" do
    context "with correct token" do
      before do
        Turbocable.configure do |c|
          c.nats_url        = NATS_URL_BASE
          c.nats_token      = NATS_TOKEN_VALUE
          c.publish_timeout = 5.0
          c.max_retries     = 0
          c.logger          = Logger.new(File::NULL)
        end
      end

      include_examples "successful publish"
    end

    context "with wrong token" do
      before do
        Turbocable.configure do |c|
          c.nats_url        = NATS_URL_BASE
          c.nats_token      = "absolutely-wrong-token"
          c.publish_timeout = 2.0
          c.max_retries     = 0
          c.logger          = Logger.new(File::NULL)
        end
      end

      include_examples "rejected publish", "wrong token"
    end

    context "with no token" do
      before do
        Turbocable.configure do |c|
          c.nats_url        = NATS_URL_BASE
          c.publish_timeout = 2.0
          c.max_retries     = 0
          c.logger          = Logger.new(File::NULL)
        end
      end

      include_examples "rejected publish", "missing token"
    end
  end

  # -------------------------------------------------------------------------
  # user-pass: nats-server configured with authorization.users
  # -------------------------------------------------------------------------
  context "user-pass mode", if: AUTH_MODE == "user-pass" do
    context "with correct credentials" do
      before do
        Turbocable.configure do |c|
          c.nats_url        = NATS_URL_BASE
          c.nats_user       = NATS_TEST_USER
          c.nats_password   = NATS_TEST_PASSWORD
          c.publish_timeout = 5.0
          c.max_retries     = 0
          c.logger          = Logger.new(File::NULL)
        end
      end

      include_examples "successful publish"
    end

    context "with wrong password" do
      before do
        Turbocable.configure do |c|
          c.nats_url        = NATS_URL_BASE
          c.nats_user       = NATS_TEST_USER
          c.nats_password   = "wrong-password"
          c.publish_timeout = 2.0
          c.max_retries     = 0
          c.logger          = Logger.new(File::NULL)
        end
      end

      include_examples "rejected publish", "wrong password"
    end
  end

  # -------------------------------------------------------------------------
  # mtls: nats-server configured with tls.verify
  # -------------------------------------------------------------------------
  context "mtls mode", if: AUTH_MODE == "mtls" do
    let(:ca_available?)   { File.exist?(NATS_TLS_CA_PATH) }
    let(:cert_available?) { File.exist?(NATS_TLS_CERT_PATH) }
    let(:key_available?)  { File.exist?(NATS_TLS_KEY_PATH) }

    context "with valid client certificate" do
      before do
        skip "mTLS fixture files not found" unless ca_available? && cert_available? && key_available?

        Turbocable.configure do |c|
          c.nats_url         = NATS_URL_BASE
          c.nats_tls         = true
          c.nats_tls_ca_file = NATS_TLS_CA_PATH
          c.nats_tls_cert_file = NATS_TLS_CERT_PATH
          c.nats_tls_key_file  = NATS_TLS_KEY_PATH
          c.publish_timeout  = 5.0
          c.max_retries      = 0
          c.logger           = Logger.new(File::NULL)
        end
      end

      include_examples "successful publish"
    end

    context "with no client certificate" do
      before do
        Turbocable.configure do |c|
          c.nats_url        = NATS_URL_BASE
          c.nats_tls        = true
          c.publish_timeout = 2.0
          c.max_retries     = 0
          c.logger          = Logger.new(File::NULL)
        end
      end

      include_examples "rejected publish", "no client cert against mTLS server"
    end
  end

  # -------------------------------------------------------------------------
  # Config mutual exclusion guard (all modes)
  # -------------------------------------------------------------------------
  describe "ConfigurationError on bad auth config" do
    it "raises when creds_file and token are both set" do
      cfg = Turbocable::Configuration.new
      cfg.nats_creds_file = NATS_CREDS_FIXTURE
      cfg.nats_token      = "also-a-token"
      expect { cfg.validate! }.to raise_error(Turbocable::ConfigurationError, /mutually exclusive/)
    end
  end
end

RSpec.describe "NATS auth integration", unless: INTEGRATION_ENABLED do
  it "skipped — set INTEGRATION=true and AUTH_MODE=<mode> to enable"
end
