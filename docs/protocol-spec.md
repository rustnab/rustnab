# Nabd Protocol Specification

## Overview

The Nabd protocol is a JSON-based TCP protocol running on port 10543 that enables communication between the core daemon (nabd) and various services. This specification defines the complete protocol for Rust implementation compatibility.

## Connection Model

### TCP Server
- **Port**: 10543 (configurable)
- **Address**: 127.0.0.1 (local only)
- **Connection Type**: Persistent TCP connections
- **Encoding**: UTF-8 JSON messages
- **Message Delimiter**: Newline character (`\n`)

### Client Connection Lifecycle
1. **Connect** – TCP connection established
2. **State Bootstrap** – nabd immediately sends the current `state` packet
3. **Subscription** – Client sends a `mode` packet to declare interest in events
4. **Active** – Bidirectional message exchange (commands, events, responses)
5. **Disconnect** – Connection closed (graceful or abrupt)

## Message Format

All messages are JSON objects terminated by a newline character.

### Base Message Structure
```json
{
  "type": "packet_type",
  "request_id": "optional_request_id",
  ...additional_fields
}
```

### Message Types
- **Commands** – Client → Server requests that nabd enqueues or executes
- **Responses** – Server → Client acknowledgements with status payloads
- **Events** – Server → Client notifications (button, RFID, ASR, state, etc.)
- **Info** – Bidirectional updates used for idle LED animations and metadata

## Packet Types

### 1. Information Packets

#### Info Request
**Direction**: Client → Server  
**Purpose**: Request daemon status and capabilities

```json
{
  "type": "info",
  "request_id": "unique_id"
}
```

**Response**:
```json
{
  "type": "response",
  "request_id": "unique_id",
  "status": "ok",
  "info": {
    "connections": [
      {
        "service": "service_name",
        "connected_at": "2023-01-01T12:00:00Z"
      }
    ],
    "hardware": {
      "model": "nabaztag_v1",
      "ears": true,
      "leds": 5,
      "sound_input": true,
      "sound_output": true,
      "rfid": "cr14"
    },
    "state": "idle"
  }
}
```

### 2. State Management

#### State Change Command
**Direction**: Client → Server  
**Purpose**: Request state change

```json
{
  "type": "state",
  "state": "idle|asleep|interactive",
  "request_id": "unique_id"
}
```

#### State Event
**Direction**: Server → Client  
**Purpose**: Notify of state changes

```json
{
  "type": "state_event",
  "state": "idle",
  "previous_state": "asleep"
}
```

### 3. Command & Message Packets

Commands and messages wrap LED, audio, and choreography instructions instead of sending low-level “led” or “play_audio” packets.

#### Command Packet
**Direction**: Client → Server  
**Purpose**: Queue a sequence for idle playback

```json
{
  "type": "command",
  "request_id": "abcd-1234",
  "cancelable": true,
  "expiration": "2025-10-05T16:30:00Z",
  "sequence": [
    {"audio": ["myapp/sounds/hello.mp3"]},
    {"choreography": "myapp/choreographies/wave.chor"}
  ]
}
```

#### Message Packet
Used for the legacy “signature + body + signature” flow.

```json
{
  "type": "message",
  "request_id": "msg-42",
  "signature": {"audio": ["hello/signature.mp3"]},
  "body": [
    {"audio": ["hello/body.mp3"], "choreography": "hello/body.chor"}
  ]
}
```

**Execution model**
- Packets are enqueued when nabd is `idle`; during `playing` they run to completion.
- Nabd automatically clears expired commands (`status = "expired"`).
- The `cancelable` flag allows the user button (short click) to abort playback.

### 4. Mode Packets & Interactive Ownership

```json
{
  "type": "mode",
  "mode": "idle",
  "events": ["button", "ears", "rfid/weather"]
}
```

- `mode = "idle"` registers for broadcast events listed in `events`. Wildcards (`"rfid/*"`, `"asr/*"`) are supported.
- `mode = "interactive"` requests exclusive control. Nabd queues the request and, once granted, subsequent commands from that writer execute immediately. The service must later send `mode: "idle"` to release control.

### 5. Sleep & Wake Control

```json
{"type": "sleep", "request_id": "sleep-1"}
```

Sleep packets are queued. Once all pending non-sleep items are done, nabd transitions to `asleep` and responds `status = "ok"`. Wake packets transition to `idle` immediately if currently asleep.

### 6. Cancel Packets

```json
{
  "type": "cancel",
  "request_id": "abcd-1234"
}
```

Cancels the in-progress command/message if the `request_id` matches and it was marked `cancelable`.

### 7. Info Packets (Idle Animations)

```json
{
  "type": "info",
  "info_id": "weather",
  "animation": {
    "tempo": 12,
    "colors": [
      {"left": "ff9900", "center": "ffffff", "right": "ff9900"}
    ]
  }
}
```

Providing an `animation` stores it in the idle info map. Sending the same `info_id` without the animation removes it. Nabd rotates stored animations whenever the idle queue is empty.

### 8. Hardware Diagnostics

#### Test Packet

```json
{
  "type": "test",
  "test": "ears",
  "request_id": "test-ears"
}
```

Supported tests: `"ears"`, `"leds"`. Tests run immediately if asleep; otherwise they queue in idle order.

#### Gestalt Packet

```json
{
  "type": "gestalt",
  "request_id": "g1"
}
```

Returns uptime, current state, connection count, and hardware metadata.

### 9. RFID Write

```json
{
  "type": "rfid_write",
  "request_id": "rfid-1",
  "tech": "st25r391x",
  "uid": "04:52:de:ad:be:ef:42",
  "picture": 12,
  "app": "nabd",
  "data": "custom payload",
  "timeout": 5.0
}
```

If hardware is absent, nabd replies with an error class such as `NFCException`. The daemon provides user feedback (LED pulse + sound) during the operation.

### 10. Configuration & Shutdown

```json
{"type": "config-update", "service": "nabd", "slot": "locale"}
```

Triggers locale reloads. Other services may define additional slots.

```json
{"type": "shutdown", "mode": "reboot", "request_id": "reboot-1"}
```

Queues a system halt or reboot after ears and LEDs are put in a safe state.

### 11. Event Packets

#### Button Event
```json
{
  "type": "button_event",
  "event": "down|up|click|double_click|hold|triple_click",
  "time": 1696521600.123
}
```

#### Ear Event
Emitted either for explicit `ears` commands (with `event: true`) or after physical movement detection.

```json
{"type": "ear_event", "ear": "left", "position": 4, "time": 1696521605.0}
```

#### RFID Event

```json
{
  "type": "rfid_event",
  "tech": "st25r391x",
  "uid": "04:52:de:ad:be:ef:42",
  "event": "detected|removed",
  "support": "formatted|foreign-data|locked|empty|unknown",
  "picture": 12,
  "app": "weather",
  "data": "serialized payload",
  "time": 1696521610.45
}
```

#### ASR Event

```json
{
  "type": "asr_event",
  "nlu": {"intent": "nlu/weather", "slots": {"city": "Paris"}},
  "time": 1696521622.9
}
```

#### State Event

```json
{"type": "state", "state": "idle"}
```

### 12. Response Payloads

All server acknowledgements use:

```json
{
  "type": "response",
  "request_id": "abcd-1234",
  "status": "ok|failure|error|expired|timeout|canceled",
  "class": "OptionalErrorClass",
  "message": "Optional detail"
}
```

- `status = "ok"` – request accepted/completed.
- `status = "failure"` – command executed but reported failure (e.g., `test` result `False`).
- `status = "error"` with `class`/`message` – validation or runtime error.
- `status = "expired"` – queued command elapsed before execution.
- `status = "timeout"` – RFID write timed out waiting for a tag.
- `status = "canceled"` – playback was canceled by user input.

### 13. Idle Queue Behaviour Summary

1. Commands, messages, tests, `sleep`, `rfid_write`, and `mode=interactive` are appended to an internal queue while nabd is `idle`.
2. `sleep` waits until all other queue items drain; if only sleeps remain, nabd transitions to `asleep` immediately.
3. While `interactive`, commands from the owning writer bypass the queue; other writers still enqueue.
4. Idle animations from `info` packets run whenever the queue is empty, rotating through stored `info_id`s.

### 9. Sleep Management

#### Sleep Command
**Direction**: Client → Server  
**Purpose**: Put rabbit to sleep

```json
{
  "type": "sleep",
  "request_id": "unique_id"
}
```

#### Wakeup Command
**Direction**: Client → Server  
**Purpose**: Wake rabbit up

```json
{
  "type": "wakeup",
  "request_id": "unique_id"
}
```

### 10. Error Handling

#### Error Response
**Direction**: Server → Client  
**Purpose**: Report command errors

```json
{
  "type": "response",
  "request_id": "unique_id",
  "status": "error",
  "error": {
    "code": "ERROR_CODE",
    "message": "Human readable error message",
    "details": "Additional error details"
  }
}
```

**Error Codes**:
- `INVALID_PACKET`: Malformed JSON or missing required fields
- `UNKNOWN_COMMAND`: Unrecognized packet type
- `HARDWARE_ERROR`: Hardware operation failed
- `STATE_ERROR`: Command not valid in current state
- `RESOURCE_BUSY`: Hardware resource is busy
- `INVALID_PARAMETER`: Parameter value out of range
- `SERVICE_NOT_FOUND`: Target service not connected
- `TIMEOUT`: Operation timed out

## Protocol State Machine

### Connection States
1. **DISCONNECTED** - No connection
2. **CONNECTED** - TCP connection established
3. **REGISTERED** - Service registered with nabd
4. **ACTIVE** - Normal operation mode

### State Transitions
```
DISCONNECTED --[connect]--> CONNECTED
CONNECTED --[register]--> REGISTERED  
REGISTERED --[disconnect]--> DISCONNECTED
REGISTERED --> ACTIVE (after successful registration)
ACTIVE --[disconnect]--> DISCONNECTED
```

## Message Flow Examples

### Service Registration Flow
1. Service connects to nabd on port 10543
2. Service sends registration packet
3. Nabd responds with success/failure
4. Service is now registered and can receive events

### Hardware Control Flow
1. Service sends LED command to nabd
2. Nabd validates command and current state
3. Nabd executes hardware operation
4. Nabd sends response to service

### Event Broadcasting Flow
1. Hardware event occurs (button press, RFID detection, etc.)
2. Nabd creates event packet
3. Nabd broadcasts event to all registered services
4. Services process event independently

## Timing and Performance

### Message Limits
- **Maximum message size**: 64KB
- **Maximum queue depth**: 1000 messages per connection
- **Connection timeout**: 30 seconds for registration
- **Heartbeat interval**: 60 seconds (optional)

### Performance Requirements
- **Command response time**: < 100ms for hardware commands
- **Event broadcast time**: < 50ms to all services
- **Maximum concurrent connections**: 20 services

## Protocol Versioning

### Version Negotiation
Services can specify protocol version during registration:

```json
{
  "type": "register",
  "service": "service_name",
  "protocol_version": "1.0",
  "request_id": "unique_id"
}
```

### Backward Compatibility
- Version 1.0: Current protocol (as specified)
- Future versions must maintain backward compatibility
- New fields can be added (ignored by older implementations)
- Existing field semantics cannot change

## Security Considerations

### Access Control
- Local connections only (127.0.0.1)
- No authentication required (local trust model)
- Services run under same user account

### Data Validation
- All JSON must be valid and well-formed
- Required fields must be present
- Parameter ranges must be validated
- String lengths must be bounded

### Resource Limits
- Connection limits prevent DoS
- Message queue limits prevent memory exhaustion
- Command rate limiting may be implemented

## Implementation Notes

### JSON Serialization
- Use standard JSON encoding
- Numbers: integers for discrete values, floats for continuous
- Colors: 6-character hex strings (RRGGBB)
- Timestamps: ISO 8601 format
- Binary data: Base64 encoding

### Connection Handling
- TCP_NODELAY should be enabled
- Keep-alive may be used
- Graceful shutdown on SIGTERM
- Proper cleanup of resources on disconnect

### Error Recovery
- Clients should reconnect on connection loss
- Commands may be retried on timeout
- Hardware errors should be logged and reported
- State inconsistencies should trigger resync

### Threading Model
- Async/await preferred for I/O operations
- Hardware operations may require dedicated threads
- Message queues for inter-thread communication
- Proper synchronization for shared state

## Testing Requirements

### Protocol Compliance Tests
- Message format validation
- State transition validation
- Error condition handling
- Performance requirements

### Integration Tests
- Multi-service communication
- Hardware operation sequences
- Event broadcasting
- Connection lifecycle

### Load Tests
- Maximum connection handling
- Message throughput
- Memory usage under load
- Recovery from overload conditions
