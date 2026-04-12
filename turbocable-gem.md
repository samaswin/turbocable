# turbocable (Ruby gem) — Scope & Architecture

> **Status:** Not started. This document is the authoritative scope and
> architectural plan for the upstream [`turbocable`](https://github.com/samaswin/turbocable)
> Ruby gem. It targets interop with `turbocable-server` as documented in
> [`docs/nats-jetstream.md`](../nats-jetstream.md),
> [`docs/websocket-protocol.md`](../websocket-protocol.md), and
> [`docs/jwt-authentication.md`](../jwt-authentication.md).

---

## 1. Purpose

`turbocable` is a pure-Ruby gem that lets any Ruby application publish messages
to the TurboCable fan-out pipeline by speaking directly to NATS JetStream. It
provides the primitives that `turbocable-rails` is built on, and can be used
standalone by Sinatra apps, Sidekiq workers, Rake tasks, CLI scripts, or any
non-Rails Ruby process.

The gem owns **one direction only**: backend → NATS → gateway. It is not a
WebSocket server, not a subscriber, and does not read from JetStream.

## 2. Scope

### In scope (MVP)

- NATS JetStream publisher that targets the `TURBOCABLE.*` subject space.
- A `Turbocable.broadcast(stream, payload)` one-liner API.
- Automatic subject encoding (`TURBOCABLE.#{stream_name}`) with stream-name
  validation matching the server's glob authorization rules.
- Payload serialization:
  - JSON (default, `actioncable-v1-json` compatible).
  - MessagePack (opt-in, `turbocable-v1-msgpack` compatible), including ext
    types for `Time` and `Symbol` aligned with the server and JS client
    deserializers.
- Connection management — lazily opened, thread-safe, process-wide singleton
  with a pluggable factory for test isolation.
- JWT signing key publisher — writes the current **RS256 public key** to the
  `TC_PUBKEYS` NATS KV bucket under the `rails_public_key` entry so that
  gateway nodes can hot-reload it. Private key material never leaves the host.
- JWT minting helper for short-lived connection tokens (`sub`, `exp`,
  `allowed_streams`, custom claims).
- Structured logging via a `Logger` injection point.
- Configurable timeouts, max retries, and an exponential backoff for publish
  failures.
- A minimal **dry-run / null adapter** so tests can assert on broadcasts
  without a running NATS server.
- `Turbocable.healthy?` — lightweight health-check helper that publishes a
  ping to a dedicated subject (e.g. `TURBOCABLE._health`). Intended for
  Kubernetes liveness probes. The server-side topology must acknowledge the
  ping for the check to pass.

### Out of scope

- WebSocket hosting or subscription.
- Reading from JetStream (the gateway does that).
- Redis fall-back (TurboCable is NATS-native).
- Rails-specific concerns — those belong in `turbocable-rails`.
- Multi-tenant key management beyond a single `rails_public_key` slot.

## 3. Target users

| User | Use case |
|------|----------|
| Ruby/Sinatra app authors | Publish broadcasts to the fan-out gateway without pulling in Rails. |
| Sidekiq / background workers | Fire-and-forget broadcasts from job code. |
| Rake / CLI scripts | Publish admin notifications from one-shot tooling. |
| `turbocable-rails` | Consume this gem as the transport layer under its DSL. |

## 4. Public API (target shape)

```ruby
require "turbocable"

Turbocable.configure do |config|
  config.nats_url          = ENV.fetch("TURBOCABLE_NATS_URL", "nats://localhost:4222")
  config.stream_name       = "TURBOCABLE"          # server default
  config.subject_prefix    = "TURBOCABLE"          # matches server
  config.default_codec     = :json                 # :json or :msgpack
  config.publish_timeout   = 2.0                   # seconds
  config.max_retries       = 3
  config.jwt_private_key   = File.read(ENV["TURBOCABLE_JWT_PRIVATE_KEY_PATH"])
  config.jwt_public_key    = File.read(ENV["TURBOCABLE_JWT_PUBLIC_KEY_PATH"])
  config.jwt_issuer        = "my-app"
  config.logger            = Rails.logger          # or any Logger
end

# Broadcast to a stream — payload is serialized by the configured codec.
Turbocable.broadcast("chat_room_42", text: "hello")

# Health-check (e.g. for Kubernetes liveness probes).
# Returns true if the server acknowledges the ping; false / raises on failure.
Turbocable.healthy?

# Mint a JWT for a browser client.
token = Turbocable::Auth.issue_token(
  sub: current_user.id,
  allowed_streams: ["chat_room_*", "notifications"],
  ttl: 15 * 60,
)

# Push the current public key to NATS KV (call once at boot / after rotation).
Turbocable::Auth.publish_public_key!
```

### Error surface

- `Turbocable::ConfigurationError` — missing required config at publish time.
- `Turbocable::PublishError` — wraps underlying NATS errors after retries.
- `Turbocable::SerializationError` — payload could not be encoded by the
  chosen codec.
- `Turbocable::InvalidStreamName` — stream name contains characters that
  would break NATS subject parsing (whitespace, wildcards, etc.).

## 5. Architecture

### Component view

```
+-------------------------+       +----------------------+
|  Application code       |       |  turbocable-rails    |
|  (Sinatra / Sidekiq /   |       |  (DSL + callbacks)   |
|   Rake / plain Ruby)    |       +----------+-----------+
+-----------+-------------+                  |
            |                                |
            v                                v
        +--------------------------------------------+
        |              Turbocable::Client            |
        |  - broadcast(stream, payload, codec:)      |
        |  - ensure_connected                        |
        |  - retry + backoff                         |
        +---------------------+----------------------+
                              |
          +-------------------+--------------------+
          |                                        |
          v                                        v
+--------------------+                 +-----------------------+
| Turbocable::Codec  |                 |  Turbocable::NatsConn |
|   ::JSON           |                 |   - JetStream context |
|   ::MsgPack        |                 |   - KV bucket handle  |
+--------------------+                 +-----------+-----------+
                                                   |
                                                   v
                                           NATS JetStream
                                          (TURBOCABLE stream,
                                           TC_PUBKEYS KV bucket)
```

### Module layout

```
lib/turbocable.rb               # top-level constants, autoload
lib/turbocable/version.rb
lib/turbocable/configuration.rb # Configuration struct + validate!
lib/turbocable/client.rb        # publish / broadcast entrypoint
lib/turbocable/nats_connection.rb
lib/turbocable/codecs.rb        # registry
lib/turbocable/codecs/json.rb
lib/turbocable/codecs/msgpack.rb
lib/turbocable/auth.rb          # JWT mint + publish_public_key!
lib/turbocable/errors.rb
lib/turbocable/null_adapter.rb  # in-memory test adapter
```

### Data flow — a single `broadcast`

1. `Turbocable.broadcast("chat_room_42", payload)` calls the client singleton.
2. The client validates the stream name against a conservative regex
   (`A-Za-z0-9_:-`), matching what the glob authorizer accepts.
3. The configured codec serializes `payload` to bytes.
4. The client lazily opens the NATS connection (TCP + JetStream context) on
   first use, guarded by a `Mutex`.
5. It calls `js.publish("TURBOCABLE.chat_room_42", encoded)` with the
   configured `publish_timeout`.
6. On `NATS::IO::Timeout` or `NATS::JetStream::Error`, it retries with
   exponential backoff up to `max_retries`, then raises `PublishError`.
7. On success, it returns the JetStream ack (stream + sequence) to the caller.

### Threading and connection model

- **One NATS client per process.** The `nats-pure` library is thread-safe;
  publishes can fan out from many Ruby threads without serialization.
- **Lazy open, fork-safe reset.** On `Process.fork` (Puma / Unicorn workers),
  the gem detects PID changes and reopens the connection in the child.
- **Forced close on exit.** An `at_exit` hook flushes pending acks and closes
  the connection.

### JWT & key management

- `Turbocable::Auth.issue_token` signs a JWT with `jwt` gem (RS256) using
  `config.jwt_private_key`.
- `Turbocable::Auth.publish_public_key!` writes `config.jwt_public_key` bytes
  into the `TC_PUBKEYS` KV bucket under the `rails_public_key` slot. This is
  the exact slot the Rust gateway watches for hot-reload.
- Key rotation flow: rotate private key locally → update `jwt_public_key` →
  call `publish_public_key!` → gateway picks it up within seconds. Old tokens
  remain valid until `exp`.

## 6. Dependencies

| Gem | Why | Notes |
|-----|-----|-------|
| `nats-pure` (~> 2.4) | Pure-Ruby NATS client with JetStream and KV support | Avoids native extensions; works in all Ruby runtimes |
| `msgpack` (~> 1.7) | MessagePack codec | Optional; only loaded if `:msgpack` codec is configured |
| `jwt` (~> 2.8) | RS256 signing | Standard choice, widely audited |
| `json` (stdlib) | Default codec | No extra dep |

Development-only: `rspec`, `rubocop`, `standard`, `simplecov`, `webmock`,
`nats-server` binary in CI for integration tests.

## 7. Compatibility contract with the server

The gem is tightly coupled to the wire expectations of `turbocable-server`.
Any change here requires a matching change in the server:

| Concern | Contract |
|---------|----------|
| Stream subject | `TURBOCABLE.<stream_name>` — `extract_stream_name` in `src/pubsub/nats.rs` strips the `TURBOCABLE.` prefix |
| Payload | Raw bytes; the server tries JSON first, then MessagePack, then null |
| Stream name charset | Must be a valid NATS subject token — no `.`, `*`, `>`, whitespace |
| KV bucket | `TC_PUBKEYS`, key `rails_public_key`, PEM-encoded RSA public key |
| JWT claims | `sub`, `exp`, `iat`, `allowed_streams` (array of glob patterns) |
| Signing algo | RS256 only — other algorithms are rejected by the gateway |

## 8. Testing strategy

1. **Unit tests** — codec round-trips, configuration validation, stream-name
   regex, JWT minting with a fixed private key and golden tokens, retry
   backoff logic using an injectable clock.
2. **Adapter tests** — the `NullAdapter` records publishes in-memory so
   dependent gems (including `turbocable-rails`) can assert on broadcasts
   without a live NATS.
3. **Integration tests (CI-only)** — spin up `nats-server --jetstream` in a
   Docker service, run end-to-end publish tests that assert on stream info
   and message contents via `nats-pure`.
4. **Server round-trip test (optional)** — a nightly job boots
   `turbocable-server` + `nats-server`, publishes from the gem, and asserts
   over a WebSocket client that the message is fanned out correctly.

## 9. Distribution

- Released to RubyGems.org as `turbocable`.
- Semver. Gem versions stay decoupled from server versions but the README
  documents the minimum compatible server version.
- Source of truth: GitHub repo `samaswin/turbocable`, CI via GitHub Actions
  (Ruby 3.1 / 3.2 / 3.3 matrix).
- `CHANGELOG.md` kept in Keep-a-Changelog format.

## 10. Milestones

| Phase | Deliverable | Exit criteria |
|-------|-------------|---------------|
| 0 — Skeleton | Gemspec, CI, empty module, `rspec` passing on a placeholder | `bundle exec rspec` green on CI |
| 1 — Core publish | `Configuration`, `Client`, `NatsConnection`, JSON codec, `Turbocable.broadcast` | Publishes a message visible on `nats sub 'TURBOCABLE.>'` |
| 2 — Codecs & errors | MessagePack codec, typed error classes, retry/backoff | Unit tests for every error path |
| 3 — Auth & KV | `Turbocable::Auth.issue_token`, `publish_public_key!`, KV watch sanity test | `turbocable-server` picks up a rotated key in < 5 s |
| 4 — Null adapter | `NullAdapter`, documented for test doubles | `turbocable-rails` can run its entire test suite against it |
| 5 — 1.0 | Docs, CHANGELOG, security notes, supported server version matrix | First `1.0.0` release on RubyGems |

## 11. Resolved decisions

| Question | Decision |
|----------|----------|
| **Health-check helper** — bundle `Turbocable.healthy?` that publishes a ping to a dedicated subject? | **Yes.** Included in MVP scope. Useful for Kubernetes liveness probes; the coupling to server-side topology is accepted. See §2 and §4 for API shape. |
| **Raw `publish(subject, bytes)` for power users?** | **Hidden.** Public surface stays purely `broadcast(stream, payload)`. `publish` will not be exposed until a concrete use case justifies it. |
| **MessagePack ext types for `Time` / `Symbol`** | **Yes.** The MessagePack codec will register ext types for `Time` and `Symbol` that match what `turbocable-server` and the JS client deserialize. Exact type IDs must be agreed on across all three packages before the codec is shipped. |
