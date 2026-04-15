# turbocable

Pure-Ruby publisher for the [TurboCable](https://github.com/samaswin/turbocable-server) fan-out pipeline. `turbocable` publishes messages to NATS JetStream on the `TURBOCABLE.*` subject tree, where `turbocable-server` picks them up and fans them out to WebSocket subscribers.

> **Status: Phase 0 — skeleton only.** The public API lands across Phases 1–4 per [`implementation-phases.md`](./implementation-phases.md). Do not depend on this gem yet.

## Requirements

- Ruby `>= 3.1`
- A running `turbocable-server` in front of `nats-server` with JetStream enabled (see `docker-compose.yml`)

## Development

```sh
bundle install
bundle exec rspec
bundle exec standardrb
gem build turbocable.gemspec
```

`bin/dev` boots a local stack (`nats:2.10` + `ghcr.io/turbocable/server:latest`) via Docker Compose and blocks until the gateway's `GET :9292/health` returns `200`.

## License

MIT — see [`LICENSE`](./LICENSE).
