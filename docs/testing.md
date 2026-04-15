# Testing

Turbocable ships a built-in null adapter so your test suite never needs a live NATS connection. All `broadcast` calls are recorded in memory and can be asserted against.

---

## Table of contents

1. [The null adapter](#the-null-adapter)
2. [RSpec setup](#rspec-setup)
3. [Minitest setup](#minitest-setup)
4. [Asserting broadcasts](#asserting-broadcasts)
5. [Testing JWT auth](#testing-jwt-auth)
6. [Integration tests](#integration-tests)

---

## The null adapter

`Turbocable::NullAdapter` is a drop-in replacement for `NatsConnection`:

- `#publish` — records every call in a class-level ring buffer (max 1 000 entries by default), returns a `NullAck` struct with `stream: "TURBOCABLE"`, `seq: 0`, `duplicate: false`.
- `#ping` — always returns `true`.
- `#key_value` — raises `NotImplementedError` (KV operations should not be called in tests using the null adapter; stub `publish_public_key!` instead).
- `#close` — no-op.

Activate it:

```ruby
Turbocable.configure { |c| c.adapter = :null }
```

Or via environment variable:

```sh
TURBOCABLE_ADAPTER=null
```

---

## RSpec setup

Add an `around` hook in `spec/spec_helper.rb` (or `spec/rails_helper.rb` for Rails):

```ruby
RSpec.configure do |config|
  config.around(:each) do |example|
    Turbocable.configure { |c| c.adapter = :null }
    example.run
  ensure
    Turbocable.reset!
    Turbocable::NullAdapter.reset!
  end
end
```

`Turbocable.reset!` tears down the client singleton so the next example starts fresh. `NullAdapter.reset!` clears the broadcast buffer.

---

## Minitest setup

```ruby
# test/test_helper.rb
class ActiveSupport::TestCase  # or Minitest::Test
  setup do
    Turbocable.configure { |c| c.adapter = :null }
  end

  teardown do
    Turbocable.reset!
    Turbocable::NullAdapter.reset!
  end
end
```

---

## Asserting broadcasts

`Turbocable::NullAdapter.broadcasts` returns an array of recorded broadcast hashes. Each element has:

| Key | Type | Description |
|-----|------|-------------|
| `:subject` | `String` | Full NATS subject, e.g. `"TURBOCABLE.chat_room_42"` |
| `:payload` | `String` | Encoded bytes as passed to the adapter |
| `:codec` | `nil` | Always `nil` at the adapter layer — codec resolution happens in `Client` |
| `:at` | `Time` | Time of the publish call |

```ruby
it "broadcasts when a message is created" do
  post "/messages", params: {room_id: 42, content: "hello"}

  broadcasts = Turbocable::NullAdapter.broadcasts
  expect(broadcasts.size).to eq(1)

  b = broadcasts.first
  expect(b[:subject]).to eq("TURBOCABLE.chat_room_42")

  # Decode the payload to inspect it (use the codec you configured)
  payload = Turbocable::Codecs::JSON.decode(b[:payload])
  expect(payload["content"]).to eq("hello")
end
```

### Decoding payloads

The null adapter stores raw bytes. Decode them with the codec your code uses:

```ruby
# JSON
payload = Turbocable::Codecs::JSON.decode(broadcasts.first[:payload])

# MessagePack (requires msgpack gem in test environment)
payload = Turbocable::Codecs::MsgPack.decode(broadcasts.first[:payload])
```

### Counting broadcasts

```ruby
expect(Turbocable::NullAdapter.broadcasts.size).to eq(3)
```

### Asserting no broadcast

```ruby
post "/messages", params: {room_id: 42, content: ""}
expect(Turbocable::NullAdapter.broadcasts).to be_empty
```

---

## Testing JWT auth

### Verifying minted tokens

`Turbocable::Auth.verify_token` decodes and verifies a token using the configured public key. Use it in specs that exercise your token-minting code:

```ruby
before do
  Turbocable.configure do |c|
    c.jwt_private_key = File.read("spec/fixtures/private.pem")
    c.jwt_public_key  = File.read("spec/fixtures/public.pem")
  end
end

it "mints a token with the correct claims" do
  token = Turbocable::Auth.issue_token(
    sub:             "user_42",
    allowed_streams: ["chat_room_42"],
    ttl:             3600
  )

  payload, _header = Turbocable::Auth.verify_token(token)

  expect(payload["sub"]).to eq("user_42")
  expect(payload["allowed_streams"]).to contain_exactly("chat_room_42")
  expect(payload["exp"]).to be > Time.now.to_i
end
```

### Stubbing `publish_public_key!`

In controller/service specs that call `publish_public_key!` at boot, stub the method so it doesn't attempt a live KV write:

```ruby
before do
  allow(Turbocable::Auth).to receive(:publish_public_key!).and_return(1)
end
```

### Invalid token assertions

```ruby
it "raises on an expired token" do
  token = Turbocable::Auth.issue_token(sub: "u1", allowed_streams: ["*"], ttl: -1)
  expect { Turbocable::Auth.verify_token(token) }.to raise_error(JWT::ExpiredSignature)
end
```

### Test key fixture

Generate a stable RSA key pair for your test suite (commit the public key; keep the private key in a secret or test-only fixture):

```sh
openssl genrsa -out spec/fixtures/private.pem 2048
openssl rsa -in spec/fixtures/private.pem -pubout -out spec/fixtures/public.pem
```

---

## Integration tests

The `spec/integration/` directory contains specs that run against a live compose stack. Skip them in unit test runs and opt in when you need full contract coverage:

```sh
# Unit tests only (no NATS, no Docker):
bundle exec rspec

# Full integration suite:
./bin/dev                           # boots stack in a terminal tab
INTEGRATION=true bundle exec rspec spec/integration
```

Integration specs wait on `GET http://localhost:9292/health` returning `200` before publishing, making server boot races visible as setup failures rather than flaky assertions.

See `spec/integration/publish_spec.rb` and `spec/integration/auth_spec.rb` for reference examples.
