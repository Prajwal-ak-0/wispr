# Murmur

Local, private dictation and meeting memory for macOS. Press a hotkey, speak, and clean,
formatted text is typed wherever your cursor is. Record a Google Meet without inviting a bot,
then search its local transcript and create a brief when you choose.

Murmur V2 also records Google Meet system audio and your microphone locally, transcribes meetings
on-device, and keeps a searchable native history. No bot joins the call.

- **Speech-to-text:** Apple's on-device speech recognizer.
- **Formatting:** a local LLM (via Ollama) removes filler words, fixes punctuation, builds lists,
  and adapts tone to the app you're typing in (casual for WhatsApp/iMessage, structured for
  Slack/Teams). It only *formats* what you said — it never answers or invents content.
- Dictation audio, meeting audio, and transcription stay on your Mac.

> The repo is named `wispr`; the app is **Murmur**.

## Requirements

- Apple Silicon Mac running macOS 26 (Tahoe) or later
- Command Line Tools (the Swift compiler) — no Xcode needed
- [Ollama](https://ollama.com) with the `qwen2.5:3b` model for polished dictation
- Arc, only if you want Google Meet detection

Optional for AI meeting briefs and questions: a signed-in Codex CLI, Claude CLI, Gemini API key,
or Vertex AI service account. Meetings still transcribe locally without one.

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

### 3. Clone, build, and launch

```bash
git clone git@github.com:Prajwal-ak-0/wispr.git
cd wispr
./setup-signing.sh   # one-time: keeps permissions across rebuilds (recommended)
./build.sh           # compiles and installs to /Applications/Murmur.app
open /Applications/Murmur.app
```

If you do not use SSH keys with GitHub, clone with:

```bash
git clone https://github.com/Prajwal-ak-0/wispr.git
```

`build.sh` prints the actual installation location. On a managed Mac where `/Applications` is not
writable, it installs to `~/Applications/Murmur.app` instead.

### 4. Grant permissions (one time)

Open **System Settings → Privacy & Security** and turn **Murmur** on under each of:

1. **Microphone**
2. **Input Monitoring**
3. **Accessibility**

For Google Meet capture, also allow **Screen & System Audio Recording**. This is not required for
dictation alone.

Then **quit and reopen** Murmur — menu-bar icon → **Quit Murmur**, then:

```bash
open /Applications/Murmur.app
```

Input Monitoring only takes effect after a relaunch. You can also find **Murmur** in Spotlight or
the Applications folder. Murmur registers itself to start at login; turn that off from the
menu-bar icon if you prefer.

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

### First-time Arc setup

1. From the Murmur menu-bar icon, choose **Set Up Google Meet in Arc…**.
2. In `arc://extensions`, enable **Developer mode**, choose **Load unpacked**, and select the
   `ArcExtension` folder that Finder reveals. It is bundled inside Murmur, so friends do not need
   to find the cloned repository after installation.
3. Grant Murmur **Screen & System Audio Recording** when macOS asks. Murmur captures audio only;
   it does not save meeting video or screenshots.

When you join a Google Meet, Murmur shows a five-second **Record this meeting?** prompt. Choose
**Record** to begin. Press `×` or let the prompt expire to skip it. It never starts recording a
Meet silently, never joins as a bot, and never controls, leaves, or closes the call.

After you leave the call, Murmur waits through brief Google Meet UI changes before it stops capture
and transcribes. This avoids accidental split transcripts when Meet rebuilds its controls.

Choose **Open Dashboard…** to view meeting status, transcripts, summaries, Q&A, retention settings,
pin or delete recordings, copy a full transcript or selected excerpt, and start a manual **Audio
note** recording. Audio is written in five-minute crash-recoverable chunks.

The dashboard labels local channels as **You** (microphone) and **Others** (system audio). It does
not yet identify individual remote participants by name.

### Meeting summaries

- **ChatGPT (Codex):** install and sign in to the Codex CLI. Murmur uses its existing ChatGPT
  login, with the model selected in **Dashboard → Settings → AI Providers**.
- **Claude:** install the Claude CLI and run `claude login`. Murmur uses `claude -p` with the
  selected model.
- **Gemini:** add a Gemini API key, or a Vertex service-account JSON path, project, and location
  in **Dashboard → Settings → AI Providers**. Vertex usage also requires the `gcloud` CLI.

Only transcript text is sent to the selected summary provider. Audio remains local. Transcription
itself always stays on-device. If no provider is connected, Murmur preserves the transcript and
shows how to connect one; it does not fail the recording.

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

The test suite covers recording controls, pause/resume, formatting selection, provider choices,
meeting timeline offsets, retention, Google Meet bridge configuration, consent safeguards, and
extension syntax.

## Troubleshooting

- **Hotkeys do nothing:** ensure **Input Monitoring** is ON for Murmur, then quit & reopen the app.
  `~/Library/Logs/Murmur.log` prints `inputMonitoring: true/false` at launch.
- **No formatting (raw text typed):** make sure Ollama is running (`ollama serve`) and the model is
  pulled (`ollama list` shows `qwen2.5:3b`). If the model is unavailable, Murmur pastes the raw
  transcript as a fallback.
- **Nothing is typed:** ensure **Accessibility** is ON for Murmur.
- **Permissions reset after a rebuild:** run `./setup-signing.sh` once, then `./build.sh` again.
- **Google Meet prompt never appears:** confirm the unpacked Murmur extension is enabled in
  `arc://extensions`, then click **Reload** on its card after rebuilding Murmur. Also confirm
  Murmur is running (menu-bar waveform icon).
- **Meeting has no remote audio:** enable **Screen & System Audio Recording** for Murmur, then
  quit and reopen it. Headphones and a selected headset microphone are supported; remote voices
  come from the system-audio track even while you are muted.
- **A brief or answer says no provider is connected:** open **Dashboard → Settings → AI Providers**
  and sign in or add the relevant Gemini/Vertex credentials.
- **Logs:** menu-bar icon → **Open Log**, or open `~/Library/Logs/Murmur.log`.
