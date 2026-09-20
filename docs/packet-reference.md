# Packet Reference Guide

## Overview

This reference describes every packet that travels across the Nabd TCP protocol. Use it alongside `docs/protocol-spec.md` when porting the Python daemon to Rust so that behaviour stays byte-for-byte compatible.

## Packet Families

1. **Information** – Query or update daemon metadata (`info`).
2. **State Control** – Change or observe the high-level rabbit state (`state`).
3. **Command Queues** – Enqueue audio/choreography playback (`command`, `message`).
4. **Mode Management** – Declare event subscriptions or request interactive ownership (`mode`).
5. **Sleep & Cancel** – Manage lifecycle commands (`sleep`, `wakeup`, `cancel`).
6. **Diagnostics** – Hardware introspection and tests (`gestalt`, `test`).
7. **RFID Write** – Program NFC tags (`rfid_write`).
8. **Configuration & Power** – Live config updates and shutdown (`config-update`, `shutdown`).
9. **Events** – Server-pushed notifications (button, ears, RFID, ASR, state).
10. **Responses** – Status packets acknowledging client requests.

## Rust Type Definitions

### Core Packet Enum

```rust
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum NabPacket {
    #[serde(rename = "info")]
    Info {
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        info_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        animation: Option<IdleAnimation>,
    },

    #[serde(rename = "state")]
    State {
        state: NabState,
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<String>,
    },

    #[serde(rename = "command")]
    Command {
        sequence: Vec<CommandItem>,
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        expiration: Option<String>,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        cancelable: bool,
    },

    #[serde(rename = "message")]
    Message {
        body: Vec<CommandItem>,
        #[serde(skip_serializing_if = "Option::is_none")]
        signature: Option<CommandItem>,
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        expiration: Option<String>,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        cancelable: bool,
    },

    #[serde(rename = "mode")]
    Mode {
        mode: NabMode,
        #[serde(skip_serializing_if = "Option::is_none")]
        events: Option<Vec<String>>,
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<String>,
    },

    #[serde(rename = "sleep")]
    Sleep {
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<String>,
    },

    #[serde(rename = "wakeup")]
    Wakeup {
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<String>,
    },

    #[serde(rename = "cancel")]
    Cancel {
        request_id: String,
    },

    #[serde(rename = "test")]
    Test {
        test: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<String>,
    },

    #[serde(rename = "gestalt")]
    Gestalt {
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<String>,
    },

    #[serde(rename = "rfid_write")]
    RfidWrite {
        tech: String,
        uid: String,
        picture: u8,
        app: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        data: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        timeout: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<String>,
    },

    #[serde(rename = "config-update")]
    ConfigUpdate {
        service: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        slot: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<String>,
    },

    #[serde(rename = "shutdown")]
    Shutdown {
        #[serde(skip_serializing_if = "Option::is_none")]
        mode: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<String>,
    },

    #[serde(rename = "button_event")]
    ButtonEvent {
        event: String,
        time: f64,
    },

    #[serde(rename = "ear_event")]
    EarEvent {
        ear: String,
        position: i16,
        time: f64,
    },

    #[serde(rename = "rfid_event")]
    RfidEvent {
        tech: String,
        uid: String,
        event: String,
        time: f64,
        #[serde(skip_serializing_if = "Option::is_none")]
        support: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        picture: Option<u8>,
        #[serde(skip_serializing_if = "Option::is_none")]
        app: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        data: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        locked: Option<bool>,
    },

    #[serde(rename = "asr_event")]
    AsrEvent {
        nlu: serde_json::Value,
        time: f64,
    },

    #[serde(rename = "state_event")]
    StateEvent {
        state: NabState,
        #[serde(skip_serializing_if = "Option::is_none")]
        previous_state: Option<NabState>,
    },

    #[serde(rename = "response")]
    Response {
        status: ResponseStatus,
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        info: Option<DaemonInfo>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<ErrorInfo>,
        #[serde(skip_serializing_if = "Option::is_none")]
        uid: Option<String>,   // RFID write success echo
    },
}
```

### Supporting Types

```rust
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum NabState {
    Idle,
    Asleep,
    Interactive,
    Playing,
    Recording,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum NabMode {
    Idle,
    Interactive,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IdleAnimation {
    pub tempo: f64,
    pub colors: Vec<IdleFrame>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IdleFrame {
    #[serde(skip_serializing_if = "Option::is_none")] pub left: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")] pub center: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")] pub right: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommandItem {
    #[serde(skip_serializing_if = "Option::is_none")] pub audio: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")] pub choreography: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ResponseStatus {
    Ok,
    Error,
    Failure,
    Expired,
    Timeout,
    Canceled,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorInfo {
    pub class: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DaemonInfo {
    pub connections: Vec<ConnectionInfo>,
    pub hardware: HardwareGestalt,
    pub state: NabState,
}
```

## Packet Details

### Information (`info`)

```json
{"type":"info","request_id":"info-1"}
```

Optional `info_id` and `animation` fields let services publish or remove idle animations. Provide an `animation` object to add/replace; omit it to delete the entry.

### State (`state`)

```json
{"type":"state","state":"interactive","request_id":"state-42"}
```

Used sparingly by administrative tools. Nabd also broadcasts `state_event` packets whenever the state changes.

### Command (`command`)

```json
{
  "type": "command",
  "request_id": "cmd-123",
  "cancelable": true,
  "expiration": "2025-10-05T17:00:00Z",
  "sequence": [
    {"audio": ["nabclockd/sounds/chime.mp3"]},
    {"choreography": "nabclockd/choreographies/pulse.chor"}
  ]
}
```

Commands are appended to the idle queue. Expired entries are acknowledged with `status = "expired"`.

### Message (`message`)

```json
{
  "type": "message",
  "request_id": "msg-5",
  "signature": {"audio": ["nabweatherd/sounds/preamble.mp3"]},
  "body": [
    {"audio": ["nabweatherd/sounds/today.mp3"], "choreography": "nabweatherd/choreographies/sunrise.chor"}
  ]
}
```

Nabd plays `signature`, then `body`, then repeats `signature` before responding.

### Mode (`mode`)

```json
{
  "type": "mode",
  "mode": "idle",
  "events": ["button", "rfid/*", "asr/weather"],
  "request_id": "mode-setup"
}
```

- `mode = "idle"` registers for broadcast events.
- `mode = "interactive"` requests exclusive control and is enqueued if another service already owns the interactive slot.

### Sleep / Wakeup

```json
{"type":"sleep","request_id":"sleep-1"}
```

Sleep queues until other items finish. Wakeups execute immediately when the daemon is asleep.

### Cancel (`cancel`)

```json
{"type":"cancel","request_id":"cmd-123"}
```

Only succeeds when the referenced playback is active and flagged `cancelable`.

### Diagnostics (`test`, `gestalt`)

```json
{"type":"test","test":"leds","request_id":"diag-1"}
```

```json
{"type":"gestalt","request_id":"diag-2"}
```

Tests can run while asleep; otherwise they queue. Gestalt returns uptime, hardware status, and the current state.

### RFID Write (`rfid_write`)

```json
{
  "type": "rfid_write",
  "request_id": "rfid-1",
  "tech": "st25r391x",
  "uid": "04:52:de:ad:be:ef:42",
  "picture": 4,
  "app": "weather",
  "data": "{"location":"PAR"}",
  "timeout": 5.0
}
```

Nabd provides LED/audio feedback while waiting for a tag. Success responses echo `uid`; timeouts report `status = "timeout"`.

### Config Update (`config-update`)

```json
{"type":"config-update","service":"nabd","slot":"locale","request_id":"cfg-1"}
```

Currently only `service = "nabd", slot = "locale"` triggers a reload.

### Shutdown (`shutdown`)

```json
{"type":"shutdown","mode":"reboot","request_id":"power-1"}
```

`mode` accepts `"reboot"`; absence triggers a halt.

### Events

Example button event:

```json
{"type":"button_event","event":"click","time":1696521600.45}
```

Example RFID detection event:

```json
{
  "type": "rfid_event",
  "tech": "st25r391x",
  "uid": "04:52:de:ad:be:ef:42",
  "event": "detected",
  "support": "formatted",
  "picture": 12,
  "app": "weather",
  "data": "{"forecast":"rain"}",
  "time": 1696521610.2
}
```

### Responses

```json
{
  "type": "response",
  "request_id": "cmd-123",
  "status": "ok"
}
```

Response statuses:

| Status     | Meaning                                                     |
|------------|-------------------------------------------------------------|
| `ok`       | Request accepted or command finished.                       |
| `failure`  | Command executed but hardware reported a failure (e.g. test).|
| `error`    | Validation or runtime error; inspect `error.class/message`.  |
| `expired`  | Command expired before it could run.                         |
| `timeout`  | RFID write timed out waiting for a tag.                      |
| `canceled` | Playback was canceled by user input.                         |

All client-initiated packets that carry `request_id` expect a matching `response` packet.

## Compatibility Notes

- Always terminate packets with `\n` and encode with UTF-8.
- Services should wait for the initial `state` packet and then send a `mode` registration before issuing commands.
- Maintain the same semantics for wildcard resources (`*`) and locale lookups described in `docs/hardware-spec.md`.

This guide, together with the protocol specification, should provide all the detail needed to keep the Rust implementation interoperable with existing Python services.
