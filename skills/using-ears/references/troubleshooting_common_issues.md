# Troubleshooting Common Issues

## Safari Does Not Work

Safari's DRM protection blocks audio capture. Switch to Chrome or Firefox for web-based audio.

## "Audio timeout" After 60 Seconds

The target app must be actively producing audio when `ears listen` starts. Ears polls for audio readiness for up to 60 seconds, then gives up.

**Fix**: Start playback in the app first, then run `ears listen`.

## Silence Detected During Recording

If ears reports sustained silence after recording has started, Screen Recording permission was likely denied or revoked.

**Fix**: Grant permission in System Settings > Privacy & Security > Screen Recording, then restart the recording.

## "Already listening" Error

Only one recording can be active at a time. Run `ears stop` to end the current recording, or `ears status` to check what is recording.

If the previous recording process crashed, ears auto-cleans stale state on the next `listen` or `status` command.

## "Setup required" Error

Run `ears setup` first. This installs whisper-cpp via Homebrew and downloads the Whisper model (~1.5 GB).

## "App not running" Error

The `--app` value must match the app's display name exactly as shown in the macOS Dock or Activity Monitor. Examples: "Google Chrome" (not "Chrome"), "Spotify", "Podcasts", "zoom.us".

## Transcription Is Slow

Whisper uses Metal GPU acceleration on Apple Silicon. Ensure whisper-cpp was installed via Homebrew (`brew install whisper-cpp`). Recordings over 1 hour are automatically chunked into segments for transcription.

## Title Already Exists

Each recording needs a unique title. Titles are sanitized to lowercase with hyphens. Choose a different `--title` value, or delete the existing file from `~/.ears/recordings/` or `~/.ears/transcripts/`.
