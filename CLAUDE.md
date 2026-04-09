# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Ears is a Swift CLI tool for macOS that captures audio from any running application using Core Audio process taps (macOS 14.4+) and transcribes it via whisper-cpp. It produces timestamped markdown transcripts.

## Build & Run Commands

```bash
swift build                     # Debug build
swift build -c release          # Release build
swift test                      # Run tests (no test suite yet)
```

Binary output: `.build/release/ears`

## Architecture

The app uses swift-argument-parser with 4 subcommands routed from `Ears.swift` (@main):

**Command flow for `ears listen`:**
1. `Listen.swift` — Orchestrates the full pipeline: finds target app PID, waits for audio, starts capture, spawns caffeinate, saves state, runs CFRunLoop, handles signals/duration/app-quit, then transcribes on stop
2. `ProcessTap.swift` — Core Audio process tap setup (PID→AudioObjectID translation, aggregate device creation, format negotiation, real-time audio callback). Converts any source format → 16kHz mono 16-bit PCM via AVAudioConverter
3. `WAVWriter.swift` — Streaming WAV writes: placeholder header → append PCM → finalize header on stop. Not thread-safe; serialized via dispatch queue
4. `Whisper.swift` — Runs whisper-cpp binary. Splits recordings >1hr into chunks with timestamp offsets. Auto-detects Metal GPU path from Homebrew
5. `Formatter.swift` — Parses SRT output → timestamped markdown with metadata

**State management:** Single `~/.ears/state.json` (RecordingState Codable struct) enforces one recording at a time. `Stop.swift` sends SIGINT to the listen process. `Status.swift` reads and displays state. Stale state (dead PID) is auto-cleaned.

**File layout under `~/.ears/`:** `state.json`, `recordings/` (WAV), `transcripts/` (markdown), `models/ggml-medium.bin`

## Key Technical Details

- **ProcessTap audio callback** runs on a real-time Core Audio thread — no blocking I/O allowed there; data is queued for writing
- **LockedValue** uses `os_unfair_lock` for the ProcessTap's `_stopped` flag (real-time safe)
- **ProcessLookup** uses NSWorkspace on macOS; `waitForAudio` polls both main PID and child PIDs (handles Chrome-like helper processes)
- **Title sanitization** in `Paths.swift` lowercases, strips unsafe chars, collapses hyphens
- **DurationParser** handles "1h30m", "45m", "90s" format strings

## Dependencies

- **swift-argument-parser** (1.3.0+): CLI parsing
- **Core Audio / AudioToolbox / AVFoundation**: Process taps, format conversion
- **Runtime tools**: whisper-cpp (Homebrew), caffeinate, curl (model download)
- Platform: macOS 14.4+ (SPM declares .v14, runtime check for 14.4)
