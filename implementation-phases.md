# turbocable — Implementation Phases

> **Source architecture:** [`turbocable-gem.md`](./turbocable-gem.md)
> **Cross-checked against:** [`samaswin/turbocable-server`](https://github.com/samaswin/turbocable-server) — `docs/nats-jetstream.md`, `docs/websocket-protocol.md`, `docs/jwt-authentication.md`, `docs/configuration.md`, `src/pubsub/nats.rs`.
> **Target:** Pure-Ruby gem `turbocable` publishing to NATS JetStream for the TurboCable fan-out pipeline.
> **Format:** Each phase lists goal, tasks, dependencies, acceptance criteria, effort estimate, and risks.

Effort estimates use ideal engineering days (1 engineer, focused). Add ~30–50% for calendar time accounting for review, CI flakes, and context switching.

## Server-contract verification summary

Findings from reading the server repo that shape this plan:

- **Subject prefix** — confirmed `TURBOCABLE.` via `SUBJECT_PREFIX` constant and `extract_stream_name` in `src/pubsub/nats.rs`. Stream name is `TURBOCABLE`, capture pattern is `TURBOCABLE.>`.
- **KV bucket / key slot** — confirmed `TC_PUBKEYS` bucket with entry `rails_public_key` (docs/jwt-authentication.md).
- **JWT** — confirmed RS256 only; required claims are `sub`, `allowed_streams`, `exp`, `iat`; patterns `*`, `prefix_*`, and exact names are supported.
- **Content-type sub-protocols** — confirmed `actioncable-v1-json` and `turbocable-v1-msgpack` at the WebSocket layer (not in the NATS payload).
- **Format detection on the server** — the gateway does **parse-try-both**: `serde_json::from_slice(..).or_else(|_| rmp_serde::from_slice(..)).unwrap_or(Null)`. Publishers do **not** signal format; the payload must be decodable by one of those two parsers.
- **MessagePack ext types** — the server uses plain `rmp_serde` with **no registered ext types for `Time` or `Symbol`**. This changes the cross-repo coordination surface: ext types only need to match between the gem and the JS client, not the server.
- **Health check** — the server exposes **HTTP `GET /health` on port 9292** returning `{status, version, connections, nats_connected}`. Also exposes `GET /metrics` (Prometheus text format) and `GET /pubkey` (current PEM public key, plain text) on the same port. There is **no `TURBOCABLE._health` NATS subject** acknowledged server-side. This invalidates the original Phase 4 health design; it's revised below.
- **JetStream stream lifecycle** — the server creates the `TURBOCABLE` stream idempotently on startup (`get_or_create_stream` in `src/pubsub/nats.rs`). Config: file storage, `subjects=TURBOCABLE.>`, `max_age=604800` (7 days), replicas configurable via `TURBOCABLE_NATS_STREAM_REPLICAS` (1 in dev, 3 in prod). The gem must **not** create or alter the stream — it publishes only. If the server hasn't booted first and the stream doesn't exist, the publish fails loudly; that's intentional.
- **KV bucket lifecycle** — the server **watches** `TC_PUBKEYS` (`src/auth/key_watcher.rs`) but does **not** create it. It also accepts a file-based public key via `TURBOCABLE_JWT_PUBLIC_KEY_PATH` and **prioritises the file over KV** when both are set. The gem's `publish_public_key!` must therefore create the bucket if missing and document that the server's file-based key must not shadow the KV one.
- **JWT claim verification scope** — `src/auth/jwt.rs` hardcodes `Algorithm::RS256` and requires `sub`, `allowed_streams`, `exp`, `iat`. It does **not** verify `iss`, `aud`, or `kid`, and uses `jsonwebtoken`'s default clock-skew tolerance. The gem should still set `iss` (cheap, future-proof) but must not depend on server-side issuer enforcement.
- **Glob patterns in `allowed_streams`** — `*` (any), `prefix_*` (wildcard), and exact names. The gem's token-minting docs must name these exactly.
- **Rate limiting behavior** — `TURBOCABLE_STREAM_RATE_LIMIT_RPS` (default 0 = off). When a stream exceeds the limit, the server drops the message before fan-out **and still acks the NATS message**. From the gem's POV, a successful publish is not a guarantee of delivery to clients.
- **Payload size** — no server-side size check beyond NATS JetStream's own `MaxMsgSize` (1 MB default). The gem should enforce a pre-publish limit to fail fast instead of relying on NATS to reject.
- **Ping cadence and close codes** — server pings every `TURBOCABLE_PING_INTERVAL` (default 30 s); close codes `3000` (auth failed), `1008` (per-IP limit), `1001` (graceful shutdown). Relevant to E2E specs.
- **Replay semantics** — clients send `hello { last_seq: u64 }` before subscribing; replayed frames carry `replayed: true` and a `seq` field for dedup. Documented for E2E test authors; the gem itself is not involved.
- **Server version** — `/health` returns `version` from `CARGO_PKG_VERSION` (currently `0.5.0`). Gem README pins a minimum server version and the E2E spec parses `/health.version` into the compatibility matrix.

## Reference topology for development and CI

All integration-level work in this plan — from Phase 1 onward — runs against
the full stack: **`turbocable-server` sitting in front of `nats-server`**.
"Integration test" in this document means publishing via the gem and
observing the message on a WebSocket served by `turbocable-server`, not just
reading back from NATS.

Two ways to run the server, both used in this plan:

1. **Docker image** (default for CI and local dev):
   `ghcr.io/turbocable/server:latest` with
   `TURBOCABLE_NATS_URL=nats://nats:4222`, port `9292` exposed. Added to the
   repo's `docker-compose.yml` as the `turbocable-server` service alongside
   `nats:2.10`.
2. **Source build** (for cross-cutting work on server/gem interface): clone
   `samaswin/turbocable-server`, `asdf install`, start
   `nats-server --jetstream &`, then `cargo build && RUST_LOG=info cargo run`.
   The server listens on `:9292`; the gem's `bin/dev --server-from-source`
   script targets this mode.

Every integration spec waits on `GET http://turbocable-server:9292/health`
returning `200` before publishing. This makes server boot races visible as
setup failures rather than assertion flakes.

---

## Phase 0 — Skeleton & Repository Bootstrap

**Goal:** Establish a releasable, CI-green empty gem so that every subsequent phase lands against a known-good baseline.

### Tasks

1. Initialize repository layout under `samaswin/turbocable` with `bundle gem turbocable` scaffolding.
2. Write `turbocable.gemspec` with metadata: authors, summary, license (MIT), homepage, required Ruby `>= 3.1`, no runtime deps yet.
3. Create `lib/turbocable.rb` and `lib/turbocable/version.rb` (start at `0.0.1`).
4. Configure RSpec with `spec/spec_helper.rb` and a single placeholder spec asserting `Turbocable::VERSION` is a string.
5. Add `standard` and `rubocop-rspec` with a minimal `.rubocop.yml` inheriting from `standard`.
6. Add `simplecov` wired to `spec_helper.rb`, failing under 90% once real code lands.
7. GitHub Actions matrix: Ruby 3.1 / 3.2 / 3.3 on `ubuntu-latest`, running `bundle exec rspec` and `bundle exec standardrb`.
8. Seed `CHANGELOG.md` (Keep a Changelog), `README.md` (one-paragraph pitch + status), `LICENSE` (MIT).
9. Enable Dependabot for `bundler` and `github-actions` ecosystems.
10. Commit a `docker-compose.yml` scaffold with `nats:2.10` and `ghcr.io/turbocable/server:latest` services. No Ruby-side wiring yet — this just pins the versions the later phases will run against, so later PRs don't have to debate the topology.
11. Commit a `bin/dev` script stub that boots the compose stack and blocks on `GET :9292/health`. Scripts that depend on it land in Phase 1.

### Dependencies

- None (first phase).

### Acceptance criteria

- `bundle exec rspec` is green locally and on CI across all three Ruby versions.
- `bundle exec standardrb` is clean.
- `gem build turbocable.gemspec` produces a valid `.gem` file.
- Repository has a protected `main` branch with CI required.

### Effort estimate

- **1 day.**

### Risks

- GitHub Actions flakes on first run (mitigate: pin `actions/checkout` and `ruby/setup-ruby` to explicit tags).
- Gemspec metadata drift with the upstream naming convention (mitigate: cross-check `turbocable-server` README before publishing).

---

## Phase 1 — Core Publish Path (JSON only)

**Goal:** Deliver the minimum useful product: `Turbocable.broadcast(stream, payload)` lands a JSON-encoded message on `TURBOCABLE.<stream>` in JetStream.

### Tasks

1. Add `nats-pure` (~> 2.4) as a runtime dependency.
2. Implement `Turbocable::Configuration` as a struct-like class with:
   - Transport: `nats_url`, `stream_name`, `subject_prefix`, `default_codec`, `publish_timeout`, `max_retries`, `max_payload_bytes` (default `1_000_000`, matches NATS `MaxMsgSize`), `logger`.
   - **NATS connection auth** (mirrors what the server's operator will configure on their side):
     - `nats_creds_file` — path to a `.creds` file (JWT+nkey, used by NGS and managed NATS).
     - `nats_user` / `nats_password` — simple auth.
     - `nats_token` — static token auth.
     - `nats_tls` (bool) — enable TLS to NATS.
     - `nats_tls_ca_file`, `nats_tls_cert_file`, `nats_tls_key_file` — mTLS material.
   - Env var bindings for each (e.g. `TURBOCABLE_NATS_URL`, `TURBOCABLE_NATS_CREDENTIALS_PATH`, `TURBOCABLE_NATS_AUTH_TOKEN`, `TURBOCABLE_NATS_TLS_CA_PATH`, `TURBOCABLE_NATS_CERT_PATH`, `TURBOCABLE_NATS_KEY_PATH`). Names intentionally match what operators will already set on the server host.
   - Mutual exclusion: `nats_creds_file` + (`nats_user`/`nats_token`) is a config error; reject at `#validate!`.
   Include `#validate!` raising `Turbocable::ConfigurationError` on missing required fields at publish time (not at configure time — lazy validation).
3. Implement `Turbocable.configure { |c| … }` and `Turbocable.config` accessors, process-wide singleton guarded by a `Mutex`.
4. Implement `Turbocable::Errors` module with `ConfigurationError`, `PublishError`, `SerializationError`, `InvalidStreamName` inheriting from a shared `Turbocable::Error` base.
5. Implement `Turbocable::Codecs::JSON` with `.encode(payload) -> String` and `.content_type -> "actioncable-v1-json"`.
6. Implement `Turbocable::Codecs` registry with `.fetch(name)` raising on unknown names.
7. Implement `Turbocable::NatsConnection`:
   - Lazily opens a `NATS::IO::Client` and JetStream context on first `#publish`. Passes `tls:`, `user_credentials:`, `user:`, `pass:`, `auth_token:` through to `nats-pure` based on which Configuration fields are set.
   - PID-aware: on `Process.pid` change vs. the value at open time, discard and reopen (fork-safety for Puma/Unicorn).
   - `at_exit` hook flushes pending acks and closes cleanly.
   - Exposes `#publish(subject, bytes, timeout:)` returning the JetStream ack.
   - Does **not** create or alter the `TURBOCABLE` JetStream stream — that's the server's job. If the stream is missing, surface the NATS "no stream matches subject" error as `PublishError` with an actionable message ("is turbocable-server running?").
8. Implement `Turbocable::Client`:
   - `#broadcast(stream_name, payload, codec: nil)`.
   - Validates `stream_name` against `/\A[A-Za-z0-9_:\-]+\z/`, raising `InvalidStreamName` otherwise.
   - Encodes via the selected codec.
   - Enforces `config.max_payload_bytes` on encoded bytes; raises `Turbocable::PayloadTooLargeError` before hitting NATS so the caller gets a useful error instead of a NATS-level rejection.
   - Delegates to `NatsConnection#publish` with the configured timeout.
   - Returns the ack. Notes that a successful ack means "NATS accepted it"; if the server has `TURBOCABLE_STREAM_RATE_LIMIT_RPS` set, the message may still be dropped before fan-out. Documented in YARD.
9. Top-level convenience: `Turbocable.broadcast(stream, payload, **kwargs)` delegates to the client singleton.
10. Unit specs: configuration validation (including NATS auth mutual exclusion and TLS path existence), stream-name regex edge cases (`.`, `*`, `>`, whitespace, unicode), JSON codec round-trip, payload-size enforcement, error wrapping.
11. Integration spec: brings up the `docker-compose.yml` stack (nats + `turbocable-server`), waits for `GET :9292/health` to return `200`, publishes via the gem, and reads the message back via `nats-pure` on `TURBOCABLE.<stream>` to confirm it landed in JetStream. (Fan-out assertion over a real WebSocket is added in Phase 3 once JWT minting is in place.)
11a. **NATS-auth integration specs**: parameterized across four auth modes, each with its own compose service variant:
    - `no-auth` (default)
    - `token-auth` (NATS conf with `authorization.token`)
    - `user-pass` (NATS conf with `authorization.users`)
    - `mtls` (NATS conf with `tls.verify`)
    Each variant boots `nats-server` with the appropriate config, starts `turbocable-server` with matching env vars, and asserts the gem (a) connects when configured correctly and (b) raises `PublishError` with a readable message when creds are wrong or missing. Creds-file auth is covered by a golden `.creds` fixture checked into `spec/fixtures/nats/`.
12. README quickstart: install, configure, one `broadcast` call, plus a pointer to `bin/dev` for booting the server stack locally.

### Dependencies

- Phase 0 complete.

### Acceptance criteria

- `Turbocable.broadcast("chat_room_42", text: "hello")` publishes a JSON message visible to `nats sub 'TURBOCABLE.>'` on a locally running `nats-server --jetstream`.
- `bin/dev` boots `nats:2.10` + `ghcr.io/turbocable/server:latest`, and `curl http://127.0.0.1:9292/health` returns `200` within 10 seconds.
- Forking the process (smoke test) results in distinct connections per child with no `EBADF` or "connection closed" errors.
- Unit test coverage ≥ 90% on touched files.
- Integration spec passes in CI against the compose stack (`nats:2.10` + `turbocable-server`), asserting both JetStream receipt and server `/health` reachability.

### Effort estimate

- **3–4 days.**

### Risks

- **`nats-pure` JetStream semantics differ subtly from the Go/Rust clients**; publish acks may surface differently (mitigate: write a spike spec first, pin the minor version, document the ack type in `Client#broadcast` YARD).
- **Fork detection race**: a thread publishing during `fork` may see a half-open connection (mitigate: guard `ensure_connected` with a mutex, recheck PID inside the critical section).
- **at_exit ordering with Rails / Sidekiq**: shutdown hooks may fire after the logger is torn down (mitigate: make the close handler defensive — swallow logger errors).
- **NATS creds-file handling on fork**: `nats-pure` may cache file descriptors from the creds file across forks (mitigate: re-read the file on reconnect-in-child, covered by the fork smoke test).
- **TLS config mismatch with server operator**: the gem and the server must agree on CA/cert/key material. (Mitigate: the README includes a side-by-side config table mapping the gem's env vars to the server's `TURBOCABLE_NATS_*` env vars.)

---

## Phase 2 — Codecs, Error Surface, Retries

**Goal:** Production-grade reliability: MessagePack codec parity with server/JS, typed error surface, exponential backoff.

### Tasks

1. Add `msgpack` (~> 1.7) as an **optional** runtime dep; require it lazily only when `:msgpack` codec is first requested. Raise a clear `LoadError` with install instructions if missing.
2. Implement `Turbocable::Codecs::MsgPack`:
   - Registers ext types for `Time` and `Symbol`.
   - Ext type IDs coordinated with **the JS client only** — the server uses plain `rmp_serde` and does not interpret ext types (confirmed in `src/pubsub/nats.rs`). Define constants `EXT_TYPE_TIME` and `EXT_TYPE_SYMBOL` and mirror them in the JS client's decoder.
   - `.content_type -> "turbocable-v1-msgpack"` (informational only — the value is not sent in the NATS payload; it's the WebSocket sub-protocol name).
   - Payload must remain decodable by `rmp_serde::from_slice`, since the gateway does parse-try-both (JSON first, then MsgPack) before forwarding bytes downstream.
3. Add round-trip specs that serialize in Ruby and deserialize with the JS client (or golden bytes captured from it). A server-side round-trip is unnecessary — the server treats the payload as opaque bytes once it parses successfully.
4. Implement retry + exponential backoff in `Turbocable::Client`:
   - Base delay 50 ms, factor 2, jitter ±20%, capped at `publish_timeout`.
   - Retries only on `NATS::IO::Timeout` and `NATS::JetStream::Error`; other exceptions propagate immediately.
   - Configurable via `config.max_retries` (default 3).
   - Clock is injectable for tests.
5. Wrap final failures in `PublishError` carrying `#cause`, `#attempts`, and `#subject`.
6. Add `Turbocable::SerializationError` wrapping any codec-level exception with context (codec name, payload class).
7. Structured logging at `:debug` (per-attempt), `:warn` (retry), `:error` (final failure). Never log payload bodies.
8. Specs: every error class is raised from at least one path; backoff timing verified with a fake clock.
9. Update README with codec selection, error handling patterns, retry semantics.

### Dependencies

- Phase 1 complete.
- **External:** Agreement with the **JS client** maintainers on MessagePack ext type IDs for `Time` and `Symbol`. The server is not in this loop — it doesn't decode ext types. Block shipping the codec until ext type IDs are recorded in both repos.

### Acceptance criteria

- MsgPack round-trip spec passes against reference bytes shared with server/JS.
- Backoff spec asserts delays `[50, 100, 200]` ms (± jitter) for `max_retries: 3`.
- No payload contents appear in any log output during spec run (enforced by a log-scraping spec).
- Unit coverage ≥ 90%.

### Effort estimate

- **3 days** (plus blocking time on the cross-repo ext-type decision).

### Risks

- **Ext type drift** — if IDs disagree between the gem and the JS client, every MsgPack message with `Time` or `Symbol` becomes lossy end-to-end. Mitigate with a shared constants fixture in both repos and a contract test that encodes in Ruby and decodes in JS.
- **`msgpack` gem native extension** conflicts with JRuby / TruffleRuby (mitigate: document that MsgPack codec requires MRI, or add a pure-Ruby fallback).
- **Retry amplification** on a flapping NATS — a high `max_retries` with short `publish_timeout` can turn a blip into a storm (mitigate: document recommended values, add a circuit-breaker follow-up ticket).

---

## Phase 3 — Auth: JWT Minting & Public Key Publishing

**Goal:** Enable gateway-compatible authentication end-to-end: mint short-lived RS256 tokens and publish the rotating public key to `TC_PUBKEYS` KV.

### Tasks

1. Add `jwt` (~> 2.8) as a runtime dep.
2. Extend `Turbocable::Configuration` with `jwt_private_key`, `jwt_public_key`, `jwt_issuer`, `jwt_kv_bucket` (default `"TC_PUBKEYS"`), `jwt_kv_key` (default `"rails_public_key"`).
3. Implement `Turbocable::Auth.issue_token(sub:, allowed_streams:, ttl:, **extra_claims)`:
   - RS256 signing with `config.jwt_private_key`.
   - Sets `iat`, `exp = iat + ttl`, plus caller claims. Also sets `iss = config.jwt_issuer` when configured — the server doesn't verify `iss` today (confirmed in `src/auth/jwt.rs`), but setting it is cheap future-proofing and helps off-platform debuggers.
   - Validates `allowed_streams` entries against the server's supported glob grammar — exact name, `prefix_*`, or `*`. Anything else (embedded `.`, trailing `*` mid-string, multiple wildcards) raises at mint time rather than at server-verify time.
   - Enforces RS256 only — raises if the key is HMAC.
4. Implement `Turbocable::Auth.publish_public_key!`:
   - Ensures the `TC_PUBKEYS` KV bucket exists; **creates it** with sensible defaults (history 1, TTL none, single replica in dev / replicas matching server stream in prod) if not. The server watches this bucket but does not create it — the gem is the source of truth for the bucket's lifecycle.
   - Writes `config.jwt_public_key` PEM bytes under `rails_public_key`.
   - Returns the KV revision.
   - Emits a `:warn` log if the server's `TURBOCABLE_JWT_PUBLIC_KEY_PATH` is also set (detected via best-effort `/pubkey` probe comparing PEM bytes) — the server prioritises the file over the KV entry, so a file-based key will silently shadow the rotation. Documented in the rotation runbook.
5. Add a `Turbocable::Auth.verify_token(token)` helper **for tests only** (not for gateway use) to catch malformed tokens in CI.
6. Golden-token specs: fixed RSA key, fixed clock → byte-for-byte stable JWT string.
7. KV integration spec: against the compose stack, call `publish_public_key!`, read the bucket back with `nats-pure`, and assert bytes match.
8. **End-to-end WebSocket fan-out spec** (required, not optional): against the compose stack, (a) publish the public key, (b) mint a token with `allowed_streams: ["chat_room_*"]`, (c) open a WebSocket to `ws://turbocable-server:9292/cable` using that token, (d) call `Turbocable.broadcast("chat_room_42", …)`, (e) assert the payload arrives on the socket within 2 seconds. This is the first test that exercises the full `gem → NATS → turbocable-server → WebSocket` contract and becomes the reference shape for all later integration specs.
9. **Hot-reload check** (nightly): rotate the key, re-publish, assert the server logs a hot-reload and that a token signed with the old key is rejected within 5 seconds.
10. Document the rotation runbook in `docs/auth.md` (rotate locally → update config → call `publish_public_key!` → old tokens valid until `exp`).

### Dependencies

- Phase 1 complete (needs `NatsConnection` for KV handle).
- Shared understanding of JWT claim shape with `turbocable-server` (§7 of architecture).

### Acceptance criteria

- Golden-token spec passes deterministically.
- `publish_public_key!` round-trip spec passes against a live `nats-server`.
- End-to-end WebSocket fan-out spec passes in CI against the compose stack (gem publishes, `turbocable-server` delivers over WebSocket).
- Manual test (documented in PR): rotate key against a running `turbocable-server` (Docker or `cargo run`), observe the gateway picks it up within 5 s with no restart.
- No private key material appears in logs or error messages (enforced by a log-scraping spec).

### Effort estimate

- **3 days.**

### Risks

- **KV bucket creation privileges**: the publishing credential may not have create permissions in production (mitigate: document required NATS permissions, fail loudly if create is rejected, support a pre-created bucket).
- **RSA key format variance** — PKCS#1 vs PKCS#8, with/without BEGIN/END headers (mitigate: normalize via `OpenSSL::PKey::RSA.new(pem)` before publish).
- **Clock skew** between Rails host and gateway can cause premature `exp` rejection. The server uses `jsonwebtoken`'s default leeway (effectively zero). Mitigate: default `ttl >= 60 s`, document NTP requirement, warn in YARD that `exp` is the only time-based check and no leeway is applied server-side.
- **Leaking private key via misconfiguration** — if someone assigns the private key to `jwt_public_key`, `publish_public_key!` would broadcast it. Mitigate: detect RSA private markers in the public-key field and raise.
- **Silent shadowing via `TURBOCABLE_JWT_PUBLIC_KEY_PATH`** — if the server operator set a file-based key, KV rotation is ignored with no error surface. Mitigate: the `publish_public_key!` warning above plus a doc callout in the rotation runbook insisting the file-based key be unset in production.

---

## Phase 4 — Null Adapter & Health Check

**Goal:** Make the gem first-class in test suites (including `turbocable-rails`) and expose a useful health signal for the publishing process.

> **Scope correction vs. architecture doc §4:** the original design had `Turbocable.healthy?` publish a ping to `TURBOCABLE._health` and wait for a server-side ack. The server repo does not implement this — it exposes an HTTP `GET /health` on port 9292 for the *gateway's* liveness and has no NATS ping acknowledger. This phase therefore redefines `Turbocable.healthy?` as a **NATS-reachability probe from the publisher's side**, not a server round-trip. Publishing a handshake to a dedicated subject is deferred to post-1.0 pending a server-side change.

### Tasks

1. Implement `Turbocable::NullAdapter`:
   - Same interface shape as `NatsConnection` (`#publish(subject, bytes, timeout:)`).
   - Records every call into an in-memory ring buffer (configurable size, default 1000).
   - Exposes `.broadcasts` returning an array of `{subject:, payload:, codec:, at:}`.
   - `.reset!` clears the buffer.
   - Thread-safe via `Mutex`.
2. Wire adapter selection through configuration: `config.adapter = :nats` (default) or `:null`.
3. Implement `Turbocable.healthy?` as a **client-side NATS probe**:
   - Ensures the connection is open; if not, opens it with a short timeout.
   - Issues a NATS `PING` (or `flush` with a bounded timeout) to confirm round-trip to the NATS server.
   - Optionally confirms JetStream context is reachable by fetching stream info for `TURBOCABLE` with a short timeout.
   - Returns `true` if all checks pass within `config.publish_timeout`, `false` on any network/timeout failure.
   - Never raises on network errors; raises only on `ConfigurationError`.
4. Add a `Turbocable.healthcheck!` variant that raises on failure for callers that want strict semantics.
5. README note clarifying this probe checks **publisher → NATS** reachability only, not the gateway. Users wanting gateway liveness should hit `turbocable-server`'s HTTP `/health` endpoint on port 9292. Include a sample `curl http://turbocable-server:9292/health` snippet and show both probes side-by-side in the Kubernetes example below.
6. README section: using the null adapter in RSpec/Minitest with a sample `around(:each)` block.
7. README section: Kubernetes `livenessProbe` example wiring `Turbocable.healthy?` through the publisher app's own `/healthz` endpoint.
8. Specs: null adapter records broadcasts; `healthy?` returns true against a live `nats-server`; `healthy?` returns false within the timeout when NATS is unreachable (use an unroutable URL).

### Dependencies

- Phase 1 complete.
- No server-side dependency (resolved by dropping the ack round-trip).

### Acceptance criteria

- `turbocable-rails` (or a minimal stand-in spec in this repo) runs its full test suite against the null adapter with no live NATS.
- `Turbocable.healthy?` returns `false` within `publish_timeout` when NATS is down — never hangs, never raises.
- README clearly distinguishes this health check from the gateway's own HTTP `/health`.
- Coverage ≥ 90%.

### Effort estimate

- **2 days.**

### Risks

- **False confidence**: a green `Turbocable.healthy?` says NATS is reachable, not that the gateway is fanning out. Mitigate with clear docs and by recommending an end-to-end synthetic check (publish → subscribe via a test WS client) for critical paths.
- **Null adapter drift** from real adapter as the latter gains features (mitigate: extract a shared abstract base or module and make both conform via a contract spec).
- **JetStream `stream_info` permissions** — the publishing credential may not have read access to stream metadata (mitigate: make the stream-info step optional, fall back to PING-only if unauthorized, emit a one-time warning).

---

## Phase 5 — 1.0 Release

**Goal:** Stabilize, document, publish to RubyGems, and commit to a compatibility matrix.

### Tasks

1. Full API documentation with YARD on every public method; `yard stats --list-undoc` returns 100% covered.
2. `docs/` directory:
   - `getting-started.md`
   - `configuration.md`
   - `codecs.md`
   - `auth.md` (includes rotation runbook from Phase 3)
   - `testing.md` (null adapter)
   - `operations.md` (health check, logging, retries, observability)
3. Security notes: threat model paragraph covering JWT handling, private key storage, log redaction, KV access.
4. Supported-server compatibility matrix in README: which `turbocable-server` versions this gem targets. Populated by the E2E spec which parses `/health.version` after boot and records it in the test report; the matrix is generated from those recorded versions rather than hand-maintained.
5. `CHANGELOG.md` filled back through Phase 0 per Keep a Changelog.
6. Version bump to `1.0.0` in `lib/turbocable/version.rb`.
7. Tagged release, pushed to RubyGems.org via a trusted `gem-push` GitHub Actions workflow (with OIDC, no long-lived API keys).
8. Announcement: GitHub release notes + a short post to the `samaswin/turbocable-server` discussions pointing at the gem.
9. Post-release: open `v1.1` milestone with deferred items (see Deferred Items below).

### Dependencies

- Phases 0–4 complete.
- At least one external consumer (`turbocable-rails` or a canary app) has run against the gem — talking to a live `turbocable-server` — for ≥ 1 week on a staging environment.

### Acceptance criteria

- `gem install turbocable` works from RubyGems.
- `bundle add turbocable` in a fresh Rails 7.1 app, configured per README, broadcasts successfully to a live `turbocable-server` (both Docker image and `cargo run` source build covered in README).
- The end-to-end WebSocket fan-out spec from Phase 3 runs green against (a) the pinned `ghcr.io/turbocable/server:latest` tag and (b) a `cargo run` build of `samaswin/turbocable-server`'s `main`. Any divergence is a release blocker.
- No open P0/P1 issues tagged `1.0-blocker`.
- Compatibility matrix present and accurate, naming specific `turbocable-server` tags.

### Effort estimate

- **2–3 days.**

### Risks

- **Docs rot by release day** — code-doc mismatches from late Phase-4 changes (mitigate: gate release on `yard stats` + a doc-example test that `eval`s every README code block).
- **RubyGems publishing credentials** — trusted publishing via OIDC is relatively new; fall back to a manual owner push if the action is misconfigured.
- **1.0 commitment** — once shipped, breaking changes require a 2.0. Lock down the public surface explicitly in `docs/api-stability.md` listing what is and isn't public.

---

## Cross-cutting concerns (apply to every phase)

- **Thread safety review** for every new shared-state component; add a concurrent spec using 8 threads hammering the new surface.
- **Fork safety review** for anything that caches file descriptors, sockets, or PID-derived state.
- **No payload logging, ever** — enforced by a log-scraping spec added in Phase 2 and re-run on every phase.
- **Semantic versioning discipline** — pre-1.0 breaking changes permitted but must appear in `CHANGELOG.md` under "Breaking".
- **CI green on all three Ruby versions** before merging any phase.

---

## Deferred items (post-1.0 backlog)

These are explicitly **out of scope for 1.0** but worth capturing so decisions are visible:

- Raw `publish(subject, bytes)` power-user API (architecture §12, currently hidden).
- Multi-tenant key slots beyond `rails_public_key`.
- Circuit breaker for sustained NATS outages.
- OpenTelemetry tracing spans around `broadcast`.
- Redis fallback — **explicitly rejected** by scope (architecture §2); do not reopen without a scope amendment.
- JRuby / TruffleRuby support for the MsgPack codec.
- **End-to-end liveness probe** (`Turbocable.healthy?` with a server-side ack). Requires a matching change in `turbocable-server` to acknowledge a dedicated health subject; not in 1.0.
- **Publisher-side rate-limit awareness.** When `TURBOCABLE_STREAM_RATE_LIMIT_RPS` drops a message, the publisher currently has no signal. Post-1.0 idea: subscribe to a server-emitted "drop" subject and emit `:warn` logs. Not in 1.0 — requires a server-side change.
- **Client dedup helper**. Replayed frames carry `seq` + `replayed: true`; a small helper for subscribers would live in `@turbocable/client`, not this gem, but worth tracking.
- **Multi-key rotation with `kid`.** Server only supports a single static key today. Adding `kid` is a joint gem+server change.
- **`/metrics` scraping for the publisher process.** The server exposes Prometheus metrics on `:9292/metrics`; a matching publisher-side `broadcast_count` / `publish_latency` histogram is deferred.

---

## Total effort

Summed ideal engineering days: **14–16 days** (≈ 3–4 calendar weeks for one engineer including review, CI, and cross-repo coordination on MessagePack ext types).

## Critical path

Phase 0 → Phase 1 → Phase 3 is the minimum viable auth-capable release.
Phase 2 can start in parallel with Phase 3 after Phase 1 merges, provided the ext-type decision isn't blocking.
Phase 4 depends only on Phase 1.
Phase 5 is strictly last.
