---
name: using-ears
description: Capture and transcribe audio from any macOS app using the ears CLI. Handles recording podcasts, audiobooks, lectures, meetings, and any app audio into timestamped markdown transcripts. Use when the user wants to record, capture, transcribe, or listen to audio from an app on their Mac.
---

# Using Ears

Ears captures audio from any running macOS app and produces timestamped markdown transcripts via Whisper.

## First-Time Setup

Run once before first use:

```bash
ears setup
```

This installs whisper-cpp (via Homebrew) and downloads the Whisper model (~1.5 GB).

**Requirements**: macOS 14.4+, Homebrew. Screen Recording permission is prompted on first use.

## Recording Audio

Start capturing from an app. The app must be running and producing audio:

```bash
ears listen --app "<app-name>" --title "<recording-name>"
```

- `--app` — Exact app display name: "Google Chrome", "Spotify", "Podcasts", "zoom.us"
- `--title` — Name for the recording and transcript (becomes the filename)

### Optional Flags

| Flag | Effect |
|------|--------|
| `--duration <time>` | Auto-stop after a duration: `1h30m`, `45m`, `90s` |
| `--output <format>` | What to keep: `md` (default), `audio`, or `both` |
| `--mute` | Silence the app's audio output while recording |

### Stop Recording

```bash
ears stop
```

Stops capture, transcribes the audio, and saves the transcript. Recordings over 1 hour are automatically chunked for transcription.

### Check Status

```bash
ears status
```

Shows the active recording: app name, title, elapsed time, file size, and auto-stop duration if set.

## Output

Transcripts are saved to `~/.ears/transcripts/` as timestamped markdown:

```
# <Title> — Transcript

Recorded: 2025-01-15T10:30:00Z
Duration: 01:23:45

[00:00:03] Welcome back to the show...
[00:00:07] Something really interesting.
```

Audio files (WAV) are saved to `~/.ears/recordings/` when using `--output audio` or `--output both`.

## Important Constraints

- **Safari does not work** — DRM blocks capture. Use Chrome or Firefox instead.
- **One recording at a time** — stop the current recording before starting another.
- **App must be producing audio** — start playback before running `ears listen`. Times out after 60 seconds of no audio.
- **~37 hour max** — WAV size limit. Use `--duration` for very long sessions.

For error messages and fixes, see [references/troubleshooting_common_issues.md](references/troubleshooting_common_issues.md).
