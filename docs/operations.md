# Operations

This guide covers health checking, logging, retry tuning, and deployment patterns for production use.

---

## Table of contents

1. [Health checks](#health-checks)
2. [Logging](#logging)
3. [Retry tuning](#retry-tuning)
4. [Kubernetes deployment](#kubernetes-deployment)
5. [Fork safety (Puma / Unicorn)](#fork-safety-puma--unicorn)
6. [Observability](#observability)

---

## Health checks

### Publisher → NATS probe

`Turbocable.healthy?` confirms the publishing process can reach the NATS server:

```ruby
Turbocable.healthy?   # => true / false (never raises on network errors)

# Strict variant — raises Turbocable::HealthCheckError on failure:
Turbocable.healthcheck!
```

This probe:
- Opens the NATS connection if not already open (with `publish_timeout` as the deadline).
- Issues a NATS `flush` (PING/PONG round-trip) and waits for the pong.
- Returns `true` only if the round-trip completes within `config.publish_timeout`.

**What it does not check:** whether `turbocable-server` is running or whether messages are reaching WebSocket clients.

### Gateway liveness probe

To check whether the gateway itself is healthy, hit its HTTP endpoint:

```sh
curl http://turbocable-server:9292/health
# {"status":"ok","version":"0.5.0","connections":12,"nats_connected":true}
```

Fields returned by the server:

| Field | Type | Description |
|---|---|---|
| `status` | `"ok"` or `"degraded"` | Overall liveness |
| `version` | String | `turbocable-server` semantic version |
| `connections` | Integer | Active WebSocket connections |
| `nats_connected` | Boolean | Whether the server is connected to NATS |

### Side-by-side probes

For full end-to-end confidence, run both probes from your publisher app's own `/healthz` endpoint:

```ruby
# config/routes.rb
get "/healthz", to: "health#show"

# app/controllers/health_controller.rb
class HealthController < ApplicationController
  def show
    nats_ok    = Turbocable.healthy?
    gateway_ok = probe_gateway

    status_code = (nats_ok && gateway_ok) ? :ok : :service_unavailable
    render json: {nats: nats_ok, gateway: gateway_ok}, status: status_code
  end

  private

  def probe_gateway
    uri = URI(ENV.fetch("TURBOCABLE_SERVER_HEALTH_URL", "http://turbocable-server:9292/health"))
    response = Net::HTTP.get_response(uri)
    response.is_a?(Net::HTTPOK)
  rescue StandardError
    false
  end
end
```

---

## Logging

### Log levels

The gem emits structured log messages at four levels:

| Level | Events |
|---|---|
| `DEBUG` | Each publish attempt (subject, attempt number) |
| `INFO` | Successful public key publication (revision number) |
| `WARN` | Each retry after a transient NATS failure; file-based key shadow warning |
| `ERROR` | Final publish failure after all retries exhausted |

Default log level is `:warn` — debug messages are suppressed unless you explicitly lower the level.

### Injecting a logger

```ruby
Turbocable.configure { |c| c.logger = Rails.logger }
```

Any object that responds to `#debug`, `#info`, `#warn`, `#error` (with a block argument form) works.

### What is never logged

**Payload bodies are never logged at any level.** The gem only logs subjects, attempt counts, error classes, and error messages. Private key material is also never logged.

### Structured logging (Ougai / Semantic Logger)

The gem uses block-form logging (`logger.warn { "..." }`) so structured loggers that accept blocks work without modification:

```ruby
require "ougai"
c.logger = Ougai::Logger.new($stdout)
```

---

## Retry tuning

### Default behaviour

| Setting | Default | Description |
|---|---|---|
| `max_retries` | `3` | Additional attempts after the first failure |
| `publish_timeout` | `2.0` | Per-attempt ack deadline; also caps backoff delay |

With defaults, a worst-case failed publish takes approximately `2.0 + 0.05 + 2.0 + 0.10 + 2.0 + 0.20 + 2.0 ≈ 8.4` seconds before raising `PublishError`.

### Tuning for low-latency environments

If your app cannot tolerate a multi-second stall on NATS unavailability:

```ruby
Turbocable.configure do |c|
  c.publish_timeout = 0.5   # tighter ack window
  c.max_retries     = 1     # fail fast
end
```

### Disabling retries

```ruby
Turbocable.configure { |c| c.max_retries = 0 }
```

### Retry error types

Only `NATS::IO::Timeout` and `NATS::JetStream::Error` trigger retries. Other errors (`PublishError` from a missing stream, `SerializationError`, `InvalidStreamName`, `PayloadTooLargeError`, `ConfigurationError`) propagate immediately with no retries — these indicate caller errors that retrying will not fix.

---

## Kubernetes deployment

### liveness probe (publisher process)

Wire `Turbocable.healthy?` through your app's own HTTP health endpoint and configure Kubernetes to poll it:

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: 3000
  initialDelaySeconds: 10
  periodSeconds: 15
  failureThreshold: 3
```

### readiness probe (gateway)

Add a separate readiness probe that also confirms the gateway is up before the pod accepts traffic:

```yaml
readinessProbe:
  httpGet:
    path: /healthz
    port: 3000
  initialDelaySeconds: 5
  periodSeconds: 10
```

### Environment variable injection

```yaml
env:
  - name: TURBOCABLE_NATS_URL
    valueFrom:
      secretKeyRef:
        name: turbocable-secrets
        key: nats_url
  - name: TURBOCABLE_JWT_PRIVATE_KEY
    valueFrom:
      secretKeyRef:
        name: turbocable-secrets
        key: jwt_private_key
  - name: TURBOCABLE_JWT_PUBLIC_KEY
    valueFrom:
      secretKeyRef:
        name: turbocable-secrets
        key: jwt_public_key
```

### At-exit behaviour

`NatsConnection` registers an `at_exit` hook that flushes pending acks and closes the connection gracefully. Kubernetes sends `SIGTERM` before `SIGKILL`; Ruby's `at_exit` hooks run on `SIGTERM` (when the process receives it via the default signal handler), so the connection should close cleanly within your `terminationGracePeriodSeconds`.

---

## Fork safety (Puma / Unicorn)

The NATS connection is PID-aware. When a child process (Puma worker, Unicorn worker) detects a PID change relative to the PID at connection-open time, it closes the inherited file descriptor and opens a new connection. The check is guarded by a mutex to prevent races where two threads both detect the stale PID simultaneously.

No special configuration is needed. The fork detection is automatic and transparent.

---

## Observability

### Metrics (post-1.0)

Publisher-side `broadcast_count` and `publish_latency` Prometheus metrics are planned for a future minor release. For now, instrument at the call site if you need metrics:

```ruby
start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
Turbocable.broadcast("stream", payload)
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
StatsD.histogram("turbocable.broadcast_duration_ms", elapsed * 1000, tags: ["stream:stream"])
```

### Gateway metrics

`turbocable-server` exposes Prometheus metrics on the same port as `/health`:

```sh
curl http://turbocable-server:9292/metrics
```

This includes fan-out counts, WebSocket connection counts, and NATS publish latencies at the gateway level.

### Tracing (post-1.0)

OpenTelemetry spans around `broadcast` are deferred to a future minor version.
