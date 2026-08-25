# DeviceKit H264

[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg?style=flat-square)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-iOS%2016.0+-blue.svg?style=flat-square)](https://developer.apple.com/ios/)
[![License](https://img.shields.io/badge/License-FSL--1.1--Apache--2.0-lightgrey.svg?style=flat-square)](LICENSE)

ReplayKit broadcast extension that streams H264 video and Opus audio over TCP. Plug it into any iOS app to get low-latency screen capture without XCUITest or any special entitlements.

## What's Inside

| Component | Description |
|-----------|-------------|
| `BroadcastUploadExtension/` | ReplayKit extension — H264 video + Opus audio over TCP |
| `h264-codec/` | Swift package: H264 encoder via VideoToolbox |
| `opus-codec/` | Swift package: Opus encoder wrapping libopus |
| `devicekit.h264/` | Host app — launches the broadcast picker on open |

## Requirements

| Platform | Minimum Version |
|----------|----------------|
| iOS      | 16.0           |
| Swift    | 5.9            |
| Xcode    | 15.0+          |

## Quick Start

Install the app on a device, open it (it auto-triggers the broadcast picker), then from your Mac:

```bash
# Forward the video port from device to localhost
ios tunnel start --userspace &
ios forward 12005 12005 &

# Play the stream with low latency
nc localhost 12005 | ffplay \
  -fflags nobuffer \
  -flags low_delay \
  -probesize 32 \
  -analyzeduration 0 \
  -framedrop \
  -sync ext \
  -f h264 -
```

Audio is on port 12006 (Opus, length-prefixed frames).

## How It Works

Launch the app — it immediately triggers the ReplayKit broadcast picker. Once the user starts the broadcast, the extension opens two TCP servers:

| Port  | Stream      | Format |
|-------|-------------|--------|
| 12005 | Video       | H264 NAL units |
| 12006 | Audio       | Opus frames (length-prefixed) |

Connect to those ports and read the stream. No handshake needed — data starts flowing as soon as you connect.

## Default Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `port` | 12005 | Video TCP port |
| `audioPort` | 12006 | Audio TCP port |
| `scaleFactor` | 0.5 | Resolution scale (50% of screen) |
| `qualityFactor` | 0.8 | H264 encoder quality |
| `expectedFrameRate` | 30 | Target frame rate |
| `averageBitRate` | 8,000,000 | Video bitrate (bps) |
| `audioBitRate` | 64,000 | Audio bitrate (bps) |

All parameters can be overridden via `setupInfo` when starting the broadcast.

## Control Protocol

Send JSON-RPC 2.0 messages to the video port (12005) to control the stream at runtime. Messages must be length-prefixed: 4-byte big-endian `uint32` followed by the JSON payload.

### Methods

#### `screencapture.setBitrate`

Update the video bitrate without restarting the broadcast. Same method name
and payload as devicekit-android's AvcServer control channel.

```json
{
  "jsonrpc": "2.0",
  "method": "screencapture.setBitrate",
  "params": {
    "bps": 2000000
  },
  "id": 1
}
```

| Field | Range | Description |
|-------|-------|-------------|
| `bps` | 100,000 – 10,000,000 | Video bitrate in bps (required); out-of-range values are clamped |

#### `screencapture.requestKeyFrame`

Re-encode the last frame as an IDR immediately (e.g. in response to a viewer PLI).

```json
{ "jsonrpc": "2.0", "method": "screencapture.requestKeyFrame", "id": 5 }
```

#### `screencapture.pause`

Pause encoding. Frames are dropped until resumed.

```json
{ "jsonrpc": "2.0", "method": "screencapture.pause", "id": 2 }
```

#### `screencapture.resume`

Resume encoding after a pause.

```json
{ "jsonrpc": "2.0", "method": "screencapture.resume", "id": 3 }
```

#### `screencapture.stop`

Stop the streamer and close both TCP servers.

```json
{ "jsonrpc": "2.0", "method": "screencapture.stop", "id": 4 }
```

## Architecture

```
devicekit-ios-h264/
  devicekit.h264/               # Host app (auto-triggers broadcast picker on launch)
  BroadcastUploadExtension/     # RPBroadcastSampleHandler → ScreenStreamer
    SampleHandler.swift         #   ReplayKit entry point, configures the streamer
    ScreenStreamer.swift         #   H264 + Opus encoding, TCP servers, JSON-RPC control
    TCPServer.swift             #   NWListener-based TCP server
  h264-codec/                   # Swift package: H264 encoder (VideoToolbox)
  opus-codec/                   # Swift package: Opus encoder (wraps libopus via submodule)
```

## Dependencies

- [libopus](https://opus-codec.org/) — Audio codec (vendored as C source via git submodule at `opus-codec/Sources/Copus`)

## License

DeviceKit H264 is released under the [Functional Source License 1.1, Apache 2.0 Future License](LICENSE).
