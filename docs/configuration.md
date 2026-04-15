# Configuration

All configuration lives in `Turbocable::Configuration`. Use `Turbocable.configure` to set options, or rely on the corresponding `TURBOCABLE_*` environment variables — every attribute reads from its env var at first access.

```ruby
Turbocable.configure do |c|
  c.nats_url        = "nats://localhost:4222"
  c.default_codec   = :json
  c.publish_timeout = 2.0
  c.max_retries     = 3
  c.logger          = Rails.logger
end
```

---

## Table of contents

1. [Transport options](#transport-options)
2. [NATS authentication](#nats-authentication)
3. [Adapter selection](#adapter-selection)
4. [JWT auth options](#jwt-auth-options)
5. [Validation](#validation)
6. [Environment variable reference](#environment-variable-reference)

---

## Transport options

### `nats_url`

NATS server URL.

- **Default:** `"nats://localhost:4222"`
- **Env:** `TURBOCABLE_NATS_URL`

```ruby
c.nats_url = "nats://nats-cluster:4222"
```

### `stream_name`

JetStream stream name. Must match the stream the server creates (`TURBOCABLE` by default — do not change without a coordinated server update).

- **Default:** `"TURBOCABLE"`
- **Env:** `TURBOCABLE_STREAM_NAME`

### `subject_prefix`

NATS subject prefix. A broadcast to stream `"chat_room_42"` publishes to `"TURBOCABLE.chat_room_42"`.

- **Default:** `"TURBOCABLE"`
- **Env:** `TURBOCABLE_SUBJECT_PREFIX`

### `default_codec`

Codec used when none is specified on `broadcast`. Must be `:json` or `:msgpack`.

- **Default:** `:json`
- **Env:** `TURBOCABLE_DEFAULT_CODEC` (accepts `"json"` or `"msgpack"`)

See [codecs.md](codecs.md) for detail on each codec.

### `publish_timeout`

Maximum seconds to wait for a JetStream publish acknowledgement on each attempt. Also caps the exponential backoff delay so retries never block longer than this window.

- **Default:** `2.0`
- **Env:** `TURBOCABLE_PUBLISH_TIMEOUT`

### `max_retries`

How many times to retry a publish after a `NATS::IO::Timeout` or `NATS::JetStream::Error` before raising `PublishError`. Set to `0` to disable retries.

- **Default:** `3`
- **Env:** `TURBOCABLE_MAX_RETRIES`

### `max_payload_bytes`

Maximum encoded payload size in bytes. The limit is checked client-side before the connection is touched, so you get a `PayloadTooLargeError` rather than a cryptic NATS rejection. Defaults to `1_000_000` (1 MB), matching NATS JetStream's `MaxMsgSize`.

- **Default:** `1_000_000`
- **Env:** `TURBOCABLE_MAX_PAYLOAD_BYTES`

### `logger`

A `Logger`-compatible object. Inject `Rails.logger`, `Ougai`, or any logger that responds to `#debug`, `#info`, `#warn`, `#error`. Defaults to `Logger.new($stdout)` at `:warn` level.

Payload bodies are never passed to the logger at any level.

```ruby
c.logger = Rails.logger
```

---

## NATS authentication

Exactly **one** auth mode may be active at a time. Combining `nats_creds_file` with `nats_user`/`nats_token` raises `ConfigurationError` at publish time.

### No auth (default)

Leave all auth fields at their defaults (nil). Works for local development and NATS servers that are network-isolated.

### Credentials file (NGS / managed NATS)

```ruby
c.nats_creds_file = "/run/secrets/turbocable.creds"
# or
ENV["TURBOCABLE_NATS_CREDENTIALS_PATH"] = "/run/secrets/turbocable.creds"
```

The `.creds` file contains a JWT identity and the corresponding nkey seed. Issued by the NATS operator. This mode is used by NGS (Synadia Cloud) and self-managed NATS clusters with operator/account/user model.

### User + password

```ruby
c.nats_user     = "turbocable"
c.nats_password = "secret"
```

Env: `TURBOCABLE_NATS_USER`, `TURBOCABLE_NATS_PASSWORD`.

### Static token

```ruby
c.nats_token = "my-shared-secret"
```

Env: `TURBOCABLE_NATS_AUTH_TOKEN`.

### TLS / mTLS

Enable TLS encryption:

```ruby
c.nats_tls = true                              # TLS only (server cert verified by system CA)
c.nats_tls_ca_file = "/etc/ssl/nats-ca.pem"   # custom CA
```

Enable mutual TLS (client certificate authentication):

```ruby
c.nats_tls         = true
c.nats_tls_ca_file    = "/etc/ssl/nats-ca.pem"
c.nats_tls_cert_file  = "/etc/ssl/turbocable-cert.pem"
c.nats_tls_key_file   = "/etc/ssl/turbocable-key.pem"
```

`nats_tls_cert_file` and `nats_tls_key_file` must be set together — having one without the other raises `ConfigurationError`.

Env vars: `TURBOCABLE_NATS_TLS` (accept `"1"`, `"true"`, `"yes"`), `TURBOCABLE_NATS_TLS_CA_PATH`, `TURBOCABLE_NATS_CERT_PATH`, `TURBOCABLE_NATS_KEY_PATH`.

#### Mapping to server env vars

| Gem attribute | Server env var |
|---|---|
| `nats_url` | `TURBOCABLE_NATS_URL` |
| `nats_creds_file` | *(server uses operator credentials, not this var)* |
| `nats_tls` | `TURBOCABLE_NATS_TLS` |
| `nats_tls_ca_file` | `TURBOCABLE_NATS_TLS_CA_PATH` |
| `nats_tls_cert_file` | `TURBOCABLE_NATS_CERT_PATH` |
| `nats_tls_key_file` | `TURBOCABLE_NATS_KEY_PATH` |

Both the gem and the server must be configured with the same CA and client credentials when mTLS is in use.

---

## Adapter selection

### `adapter`

Selects the publish backend.

- **`:nats`** (default) — live NATS JetStream connection
- **`:null`** — records broadcasts in memory, never opens a socket; intended for test suites

```ruby
c.adapter = :null   # in test environments
```

Env: `TURBOCABLE_ADAPTER` (accepts `"nats"` or `"null"`).

See [testing.md](testing.md) for detailed null adapter usage.

---

## JWT auth options

These are used by `Turbocable::Auth`. See [auth.md](auth.md) for the full guide.

| Attribute | Env var | Default | Notes |
|---|---|---|---|
| `jwt_private_key` | `TURBOCABLE_JWT_PRIVATE_KEY` | `nil` | PEM RSA private key. Required for `issue_token`. |
| `jwt_public_key` | `TURBOCABLE_JWT_PUBLIC_KEY` | `nil` | PEM RSA public key. Required for `publish_public_key!` and `verify_token`. |
| `jwt_issuer` | `TURBOCABLE_JWT_ISSUER` | `nil` | Optional `iss` claim. Server doesn't verify it but it aids debugging. |
| `jwt_kv_bucket` | `TURBOCABLE_JWT_KV_BUCKET` | `"TC_PUBKEYS"` | NATS KV bucket name the server watches. |
| `jwt_kv_key` | `TURBOCABLE_JWT_KV_KEY` | `"rails_public_key"` | Entry key within the bucket. |

**PEM newlines in env vars**: most secret managers store PEM with `\n` literal characters. The gem's env-var reader automatically converts `\n` → newline, so exporting like this works:

```sh
export TURBOCABLE_JWT_PRIVATE_KEY="-----BEGIN RSA PRIVATE KEY-----\nMIIE...\n-----END RSA PRIVATE KEY-----"
```

---

## Validation

`Configuration#validate!` is called lazily at publish time (not at configure time), so processes that configure Turbocable but never publish don't pay the validation cost. It raises `Turbocable::ConfigurationError` on:

- `nats_creds_file` combined with `nats_user`/`nats_token`
- `nats_tls_cert_file` set without `nats_tls_key_file` (or vice versa)
- Any TLS file path that does not exist on disk

---

## Environment variable reference

| Env var | Config attr | Default |
|---|---|---|
| `TURBOCABLE_NATS_URL` | `nats_url` | `nats://localhost:4222` |
| `TURBOCABLE_STREAM_NAME` | `stream_name` | `TURBOCABLE` |
| `TURBOCABLE_SUBJECT_PREFIX` | `subject_prefix` | `TURBOCABLE` |
| `TURBOCABLE_DEFAULT_CODEC` | `default_codec` | `json` |
| `TURBOCABLE_PUBLISH_TIMEOUT` | `publish_timeout` | `2.0` |
| `TURBOCABLE_MAX_RETRIES` | `max_retries` | `3` |
| `TURBOCABLE_MAX_PAYLOAD_BYTES` | `max_payload_bytes` | `1000000` |
| `TURBOCABLE_ADAPTER` | `adapter` | `nats` |
| `TURBOCABLE_NATS_CREDENTIALS_PATH` | `nats_creds_file` | — |
| `TURBOCABLE_NATS_USER` | `nats_user` | — |
| `TURBOCABLE_NATS_PASSWORD` | `nats_password` | — |
| `TURBOCABLE_NATS_AUTH_TOKEN` | `nats_token` | — |
| `TURBOCABLE_NATS_TLS` | `nats_tls` | `false` |
| `TURBOCABLE_NATS_TLS_CA_PATH` | `nats_tls_ca_file` | — |
| `TURBOCABLE_NATS_CERT_PATH` | `nats_tls_cert_file` | — |
| `TURBOCABLE_NATS_KEY_PATH` | `nats_tls_key_file` | — |
| `TURBOCABLE_JWT_PRIVATE_KEY` | `jwt_private_key` | — |
| `TURBOCABLE_JWT_PUBLIC_KEY` | `jwt_public_key` | — |
| `TURBOCABLE_JWT_ISSUER` | `jwt_issuer` | — |
| `TURBOCABLE_JWT_KV_BUCKET` | `jwt_kv_bucket` | `TC_PUBKEYS` |
| `TURBOCABLE_JWT_KV_KEY` | `jwt_kv_key` | `rails_public_key` |
