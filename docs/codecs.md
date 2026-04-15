# Codecs

Turbocable encodes payloads before publishing them to NATS. The codec is selected per-process via `config.default_codec` or overridden per-call via the `codec:` keyword.

```ruby
# Process-wide default
Turbocable.configure { |c| c.default_codec = :json }

# Per-call override
Turbocable.broadcast("stream", payload, codec: :msgpack)
```

---

## Table of contents

1. [JSON codec](#json-codec)
2. [MessagePack codec](#messagepack-codec)
3. [How the server detects the format](#how-the-server-detects-the-format)
4. [Choosing a codec](#choosing-a-codec)
5. [Writing a custom codec](#writing-a-custom-codec)

---

## JSON codec

**Name:** `:json`
**Gem dependency:** none (always available)
**WebSocket sub-protocol:** `actioncable-v1-json`

The default codec. Encodes payloads as UTF-8 JSON strings using `JSON.generate`. Symbols in Hash keys are serialized as strings.

```ruby
Turbocable.broadcast("events", {type: "order_placed", order_id: 99})
# NATS payload: '{"type":"order_placed","order_id":99}'
```

### Accepted payload types

`Hash`, `Array`, `String`, `Integer`, `Float`, `TrueClass`, `FalseClass`, `NilClass`, `Symbol`. Any other type raises `Turbocable::SerializationError` before `JSON.generate` is called — this prevents silent coercion (newer `json` gem versions call `#to_s` on unknown types rather than raising).

### Round-trip

```ruby
bytes = Turbocable::Codecs::JSON.encode({foo: "bar"})  # => '{"foo":"bar"}'
data  = Turbocable::Codecs::JSON.decode(bytes)         # => {"foo" => "bar"}
```

---

## MessagePack codec

**Name:** `:msgpack`
**Gem dependency:** `msgpack ~> 1.7` (**optional** — add to your Gemfile explicitly)
**WebSocket sub-protocol:** `turbocable-v1-msgpack`

A compact binary format. Typically 20–40% smaller than JSON for typical broadcast payloads. Loaded lazily on first use — if the gem is absent a clear `LoadError` is raised.

```ruby
# Gemfile
gem "msgpack", "~> 1.7"
```

```ruby
Turbocable.configure { |c| c.default_codec = :msgpack }
Turbocable.broadcast("events", {type: "order_placed", order_id: 99})
```

### Ext types (coordinated with the JS client)

Standard MessagePack has no native `Time` or `Symbol` type. Turbocable registers extension types for them. The IDs are the shared contract between this gem and the TurboCable JS client decoder — **do not change them** without a coordinated update on the JS side.

| Ext ID | Ruby type | Encoding |
|:------:|-----------|----------|
| `0` | `Symbol` | UTF-8 string bytes |
| `1` | `Time` | big-endian int64 (seconds since epoch) + int32 (nanoseconds) |

Accessing the constants:

```ruby
Turbocable::Codecs::MsgPack::EXT_TYPE_SYMBOL  # => 0
Turbocable::Codecs::MsgPack::EXT_TYPE_TIME    # => 1
```

### Server interoperability

`turbocable-server` uses plain `rmp_serde::from_slice` with **no registered ext types**. It accepts any valid MessagePack payload and forwards the raw bytes to WebSocket clients. The gateway never inspects or transforms ext-type values — they are round-tripped to the browser unchanged.

This means:
- `Symbol` and `Time` ext types reach the JS client intact and must be decoded there.
- The server cannot reject a payload because of unknown ext types.

### MRI only

The `msgpack` gem's native extension is MRI-only. JRuby and TruffleRuby are not supported for the `:msgpack` codec. Stick to `:json` on those runtimes.

### Round-trip

```ruby
bytes = Turbocable::Codecs::MsgPack.encode({at: Time.now, tag: :urgent})
data  = Turbocable::Codecs::MsgPack.decode(bytes)
# => {"at" => #<Time ...>, "tag" => :urgent}
```

---

## How the server detects the format

The gateway does **parse-try-both**: it calls `serde_json::from_slice(..)` first, then falls back to `rmp_serde::from_slice(..)` on any JSON parse error. The gem does **not** signal the format in the NATS message headers or payload — the payload itself must be decodable by one of those two parsers.

Implications:
- A valid JSON payload will always be detected as JSON, even if you specified `:msgpack` (edge case: a MessagePack encoding of a short integer may happen to be valid JSON, but this is harmless because the gateway passes the bytes through to the client regardless).
- You cannot "sneak" a JSON payload into the MessagePack path or vice versa.

---

## Choosing a codec

| | JSON | MessagePack |
|---|---|---|
| Default | yes | no |
| Extra gem | no | `msgpack ~> 1.7` |
| Payload size | larger (text) | ~20–40% smaller |
| `Time` / `Symbol` | ❌ (loses type) | ✅ (ext types) |
| JS client complexity | minimal | requires ext-type decoder |
| MRI / JRuby / TruffleRuby | all | MRI only |

**Use JSON** when: you want zero extra dependencies, your JS client already handles ActionCable JSON, or you're on a non-MRI runtime.

**Use MessagePack** when: payload size matters (high-volume streams, mobile clients), or you need round-trip fidelity for `Time` and `Symbol` through to the JS client.

---

## Writing a custom codec

A codec is any module that responds to `.encode(payload)`, `.decode(bytes)`, and `.content_type`.

```ruby
module MyCodec
  def self.encode(payload)
    MySerializer.dump(payload)
  end

  def self.decode(bytes)
    MySerializer.load(bytes)
  end

  def self.content_type
    "application/x-myformat"
  end
end
```

Register it with the `Codecs` module before use:

```ruby
# Monkey-patch the frozen registry (development/test only)
Turbocable::Codecs::REGISTRY = Turbocable::Codecs::REGISTRY
  .merge(my_codec: MyCodec).freeze
```

> **Note:** Custom codecs are not part of the supported public API surface for 1.0. The registry API may change in a future minor version.
