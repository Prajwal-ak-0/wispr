# Murmur

Local, private dictation for macOS. Press a hotkey, speak, and clean, formatted text is typed
wherever your cursor is — fully on-device, no cloud, no subscription.

Murmur V2 also records Google Meet system audio and your microphone locally, transcribes meetings
on-device, and keeps a searchable native history. No bot joins the call.

- **Speech-to-text:** Apple's on-device speech recognizer.
- **Formatting:** a local LLM (via Ollama) removes filler words, fixes punctuation, builds lists,
  and adapts tone to the app you're typing in (casual for WhatsApp/iMessage, structured for
  Slack/Teams). It only *formats* what you said — it never answers or invents content.
- Nothing leaves your machine.

> The repo is named `wispr`; the app is **Murmur**.

## Requirements

- Apple Silicon Mac running macOS 26 (Tahoe) or later
- Command Line Tools (the Swift compiler) — no Xcode needed
- [Ollama](https://ollama.com) with the `qwen2.5:3b` model

## Install

### 1. Command Line Tools (Swift)

```bash
xcode-select --install
```

Skip if `swift --version` already prints a version.

### 2. Ollama + model

```bash
brew install ollama        # or download the app from https://ollama.com
ollama serve               # start the local server (run in its own terminal; skip if already running)
ollama pull qwen2.5:3b     # ~2 GB, one-time download
```

### 3. Clone & build

```bash
git clone git@github.com:Prajwal-ak-0/wispr.git
cd wispr
./setup-signing.sh   # one-time: keeps permissions across rebuilds (recommended)
./build.sh           # compiles and installs to /Applications/Murmur.app
```

### 4. Grant permissions (one time)

Open **System Settings → Privacy & Security** and turn **Murmur** on under each of:

1. **Microphone**
2. **Input Monitoring**
3. **Accessibility**

Then **quit and reopen** the app — menu-bar mic icon → **Quit Murmur**, then:

```bash
open /Applications/Murmur.app
```

Input Monitoring only takes effect after a relaunch. You can also find **Murmur** in Spotlight or
the Applications folder.

## Use

- **Double-tap ⌘** → start recording; **double-tap ⌘** again → stop, format, and type it.
  (Hands-free — good for long dictation.)
- **Hold ⌥** → push-to-talk; release to stop. (Good for quick phrases.)
- **Space** → pause while recording; press **Space** again to resume. You can also use the
  button on the floating recorder or the menu-bar item. Your
  transcript is kept in memory while paused, so you can continue after an interruption.
- **Finish** → use the checkmark on the floating recorder, the menu-bar item, or double-tap ⌘.
- **Esc** → cancel without typing anything.

A compact recorder appears while recording, with live voice bars and clear pause/resume and finish
controls. Its label and the menu-bar icon reflect whether Murmur is listening, paused, or processing.

## Google Meet recording

### First-time setup

1. From the Murmur menu-bar icon, choose **Set Up Google Meet in Arc…**.
2. In `arc://extensions`, enable **Developer mode**, choose **Load unpacked**, and select the
   revealed `ArcExtension` folder.
3. Grant Murmur **Screen & System Audio Recording** when macOS asks. Murmur captures audio only;
   it does not save meeting video or screenshots.

When **Automatically record joined Google Meets** is enabled in the dashboard settings, Murmur
starts only after the Meet call UI shows that you joined. Hanging up, closing the tab, or losing the
extension heartbeat safely stops recording and begins transcription.

Choose **Open Dashboard…** to view meeting status, transcripts, summaries, Q&A, retention settings,
or to start a manual meeting recording. Audio is written in five-minute crash-recoverable chunks.

### Meeting summaries

- **ChatGPT (Codex):** uses the locally installed Codex CLI and its existing ChatGPT login.
- **Claude:** uses `claude -p`; sign in with `claude login` first.
- **Gemini:** uses Gemini CLI. Configure a Gemini API key or Vertex service-account JSON, project,
  and location from Meeting settings.

Only transcript text is sent to the selected summary provider. Audio remains local. Transcription
itself always stays on-device.

Murmur adds itself to your Login Items on first launch, so it's always running and the hotkeys are
always available. You can turn this off from the menu-bar mic icon → **Start at Login**.

## How it works

1. Mic audio is transcribed on-device with Apple `SpeechAnalyzer`.
2. The raw transcript goes to a local `qwen2.5:3b` model (Ollama on `localhost`) that only cleans
   and formats it.
3. The result is pasted at your cursor.

All tunables — model, hotkey timing, the formatter prompt, and the per-app styles — live in
[`Sources/Murmur/Config.swift`](Sources/Murmur/Config.swift).

## Rebuild after changes

```bash
./build.sh
```

With `./setup-signing.sh` run once, rebuilds keep your permissions (no re-granting).

## Tests

```bash
./Tests/run-tests.sh
```

The tests cover recording-control availability across idle, listening, paused, and processing
states, plus app-aware formatting selection.

## Troubleshooting

- **Hotkeys do nothing:** ensure **Input Monitoring** is ON for Murmur, then quit & reopen the app.
  `~/Library/Logs/Murmur.log` prints `inputMonitoring: true/false` at launch.
- **No formatting (raw text typed):** make sure Ollama is running (`ollama serve`) and the model is
  pulled (`ollama list` shows `qwen2.5:3b`). If the model is unavailable, Murmur pastes the raw
  transcript as a fallback.
- **Nothing is typed:** ensure **Accessibility** is ON for Murmur.
- **Permissions reset after a rebuild:** run `./setup-signing.sh` once, then `./build.sh` again.
- **Logs:** menu-bar icon → **Open Log**, or open `~/Library/Logs/Murmur.log`.
