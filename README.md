# Ears

Ears for your AI. Capture and transcribe audio from any macOS app. Record a podcast in Chrome, an audiobook in Audible, a lecture in Zoom, get a timestamped markdown transcript.

## Quick start

```bash
brew install whisper-cpp
git clone https://github.com/richardshaw/ears-cli && cd ears-cli
swift build -c release
cp .build/release/ears /usr/local/bin/

ears setup          # download Whisper model (~1.5 GB)
ears listen --app "Google Chrome" --title "episode-42"
# ... when done:
ears stop           # transcribes and saves to ~/.ears/transcripts/
```

## Requirements

- macOS 14.4+ (uses Core Audio process taps)
- Homebrew (for whisper-cpp)
- Screen Recording permission — macOS will prompt on first use, or grant manually in System Settings > Privacy & Security > Screen Recording

## Commands

### `ears listen`

Start capturing audio from an app.

```
ears listen --app <app-name> --title <name> [--duration <time>] [--output <format>]
```

| Flag | Required | Description |
|------|----------|-------------|
| `--app` | Yes | App display name (e.g. "Google Chrome", "Spotify") |
| `--title` | Yes | Name for the recording and transcript |
| `--duration` | No | Auto-stop after time: `1h30m`, `45m`, `90s` |
| `--output` | No | What to keep: `md` (default), `audio`, or `both` |
| `--mute` | No | Silence the app's audio output while recording |

The target app must be running and producing audio. Prevents Mac sleep automatically via `caffeinate`.

### `ears stop`

Stop the current recording and transcribe.

```
ears stop
```

Recordings longer than 1 hour are automatically chunked and transcribed in segments with adjusted timestamps.

### `ears status`

Show what's currently recording.

```
ears status
```

Displays app name, title, elapsed time, file size, and auto-stop duration (if set).

### `ears setup`

Install dependencies and download the Whisper model.

```
ears setup
```

Checks for: macOS version, Homebrew, whisper-cpp, creates `~/.ears/` directories, downloads `ggml-medium.bin` (~1.5 GB) from HuggingFace.

## Output format

Transcripts are saved to `~/.ears/transcripts/` as markdown:

```markdown
# Episode 42 — Transcript

Recorded: 2025-01-15T10:30:00Z
Duration: 01:23:45

[00:00:03] Welcome back to the show. Today we're going to talk about
[00:00:07] something really interesting.
[00:00:12] Let's dive right in.
```

## How it works

1. **Process tap** — Uses macOS 14.4+ Core Audio process taps (`AudioHardwareCreateProcessTap`) to capture audio directly from a target app's output. No virtual audio devices needed.
2. **Format conversion** — Converts captured audio to 16kHz mono 16-bit PCM via `AVAudioConverter` and streams to a WAV file.
3. **Transcription** — Runs whisper-cpp (with Metal GPU acceleration) on the WAV. Long recordings are split into 1-hour chunks with timestamp offsets.
4. **Output** — Converts SRT output to clean markdown with timestamps.

## File structure

```
~/.ears/
├── state.json          # current recording state
├── recordings/         # WAV files
├── transcripts/        # markdown transcripts
└── models/
    └── ggml-medium.bin # Whisper model
```

## Limitations

- **Safari blocks audio** — DRM protection prevents capture. Use Chrome or Firefox instead.
- **One recording at a time** — only a single app can be captured concurrently.
- **~37 hour max** — WAV 32-bit size limit at 16kHz mono. Use `--duration` for long sessions.
- **App must be producing audio** — recording times out after 60 seconds of silence. If silence is detected during recording, it may indicate Screen Recording permission was denied.
- **macOS only** — Core Audio process taps are a macOS-specific API.

## License

MIT
