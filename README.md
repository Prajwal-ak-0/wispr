# Murmur

Local meeting capture and transcription for macOS. Murmur records Google Meet system audio and
your microphone without inviting a bot, then keeps a searchable native meeting history.

- **Meeting transcription:** choose Gemini diarization or Apple's on-device speech recognizer.
- **Meeting memory:** transcripts, summaries, Q&A, retention, and crash-recoverable audio chunks.
- **Privacy:** local capture by default; only the selected cloud transcription or summary provider
  receives meeting data.

> The repo is named `wispr`; the app is **Murmur**.

## Requirements

- Apple Silicon Mac running macOS 26 (Tahoe) or later
- Command Line Tools (the Swift compiler) — no Xcode needed
- Arc, only if you want Google Meet detection

Optional for AI meeting briefs and questions: a signed-in Codex CLI, Claude CLI, Gemini API key,
or Vertex AI service account. Meetings still transcribe locally without one.

## Install

### 1. Command Line Tools (Swift)

```bash
xcode-select --install
```

Skip if `swift --version` already prints a version.

### 2. Clone, build, and launch

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

### 3. Grant permissions (one time)

Open **System Settings → Privacy & Security** and turn **Murmur** on for:

1. **Microphone**
2. **Screen & System Audio Recording**

Then **quit and reopen** Murmur — menu-bar icon → **Quit Murmur**, then:

```bash
open /Applications/Murmur.app
```

You can also find **Murmur** in Spotlight or the Applications folder. Murmur registers itself to
start at login so Google Meet detection is available; turn that off from the menu-bar icon if you
prefer.

## Google Meet recording

### First-time Arc setup

1. From the Murmur menu-bar icon, choose **Set Up Google Meet in Arc…**.
2. In `arc://extensions`, enable **Developer mode**, choose **Load unpacked**, and select the
   `ArcExtension` folder that Finder reveals. It is bundled inside Murmur, so friends do not need
   to find the cloned repository after installation.
3. Grant Murmur **Screen & System Audio Recording** when macOS asks. Murmur captures audio only;
   it does not save meeting video or screenshots.

When you join a Google Meet, Murmur shows a fifteen-second **Record this meeting?** prompt. Choose
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

Only transcript text is sent to the selected summary provider. If no provider is connected, Murmur
preserves the transcript and shows how to connect one; it does not fail the recording.

### Meeting transcription

Every finished meeting is mixed down to a single `meeting.mp3` inside its own folder under
`~/Library/Application Support/Murmur/Meetings/<meeting-id>/`, then transcribed. The mp3 is written
**before** transcription starts, so the recording never depends on transcription succeeding.

Pick the engine in **Dashboard → Settings → General → Transcription**:

| | Gemini (cloud) — default | On-device |
|---|---|---|
| Speakers | Every voice separated, named where a name is spoken | *You* vs *Others* only |
| Audio leaves the Mac | Yes, to your own Google Cloud project | Never |
| Speed | ~2–4 min for a 30-min meeting | ~1 min |
| Needs setup | Service account (below) | Nothing |

If Gemini is unconfigured, unreachable, or fails, the meeting falls back to on-device transcription
and the dashboard shows which engine ran. A meeting is never left without a transcript.

#### Setting up Gemini transcription

**1. Create a service account with Vertex AI access**

In the Google Cloud project you want to bill:

```bash
gcloud config set project YOUR_PROJECT_ID
gcloud services enable aiplatform.googleapis.com
gcloud iam service-accounts create murmur-transcribe \
    --display-name "Murmur meeting transcription"
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
    --member "serviceAccount:murmur-transcribe@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
    --role roles/aiplatform.user
```

`roles/aiplatform.user` is all it needs. Nothing else is required — Murmur signs its own JWT and
exchanges it for an access token, so **`gcloud` does not need to be installed** on the Mac that
runs Murmur, and no `gcloud auth login` is needed.

**2. Download the key and put it where Murmur looks**

```bash
mkdir -p ~/armor1/armor-adk
gcloud iam service-accounts keys create ~/armor1/armor-adk/vertex-creds.json \
    --iam-account murmur-transcribe@YOUR_PROJECT_ID.iam.gserviceaccount.com
chmod 600 ~/armor1/armor-adk/vertex-creds.json
```

**Default location: `~/armor1/armor-adk/vertex-creds.json`.** That exact path is what Murmur reads
when nothing is configured. To keep the key somewhere else, put the full path in
**Dashboard → Settings → AI Providers → Gemini → Vertex service-account JSON path**.

The file is the standard service-account JSON and must contain `client_email`, `private_key`, and
`project_id`:

```json
{
  "type": "service_account",
  "project_id": "your-project-id",
  "private_key_id": "…",
  "private_key": "-----BEGIN PRIVATE KEY-----\n…\n-----END PRIVATE KEY-----\n",
  "client_email": "murmur-transcribe@your-project-id.iam.gserviceaccount.com",
  "token_uri": "https://oauth2.googleapis.com/token"
}
```

Never commit this file. It grants access to your Cloud project; keep it outside the repo (the
default path already is) and `chmod 600` it.

**3. Leave the project field alone unless you mean it**

The **Vertex project** box under *AI Providers → Gemini* is shared with meeting summaries. If it
names a project your service account cannot access, transcription logs the rejection and retries
with the project named inside the JSON, so it still works — but clearing the box removes a wasted
round trip per meeting. Murmur uses the JSON's own `project_id` when the box is empty.

**4. Install ffmpeg (recommended)**

```bash
brew install ffmpeg
```

ffmpeg is what produces `.mp3`. Without it Murmur mixes to `.m4a` instead, which every part of the
pipeline still accepts — you just get a larger file. A path can also be set in the `ffmpegPath`
user default.

**5. Verify without sitting through a meeting**

Re-run the whole pipeline against a meeting already on disk:

```bash
/Applications/Murmur.app/Contents/MacOS/Murmur --transcribe-meeting <meeting-id> --engine gemini --dry-run
```

Meeting ids are the folder names under `~/Library/Application Support/Murmur/Meetings/`. Drop
`--dry-run` to save the result. It prints the engine used, elapsed time, speakers found, turn
count, and how much of the recording was covered. `--engine local` forces the on-device path.

Progress and failures are logged to `~/Library/Logs/Murmur.log`.

#### What the model is and is not good at

- **Speaker names** are inferred from what is said aloud. Murmur only accepts a name when the audio
  settles it — someone introduces themselves, or answers to it — because a name in an utterance
  usually belongs to the person being *addressed*, not the speaker. The dashboard shows the quote
  behind every name, so you can check.
- **Which voice is yours** is decided from the microphone-only track, not from the words. Murmur
  measures how much of the meeting your mic was actually active for; if it was near-silent, no
  speaker is marked as you rather than guessing wrong.
- **Timestamps are estimates.** Over a long recording the model's clock drifts, so Murmur compares
  the transcript's claimed end against the real audio length and rescales when it overshoots,
  flagging the transcript as approximate. Turn *order* is always correct. If you need exact seek
  points, the on-device engine derives them from real audio offsets.

## How it works

1. The Arc extension reports Google Meet join/leave state to Murmur over localhost.
2. Murmur asks for consent, then records system audio and microphone audio locally.
3. The selected transcription engine creates the transcript; optional providers create summaries
   and answer questions from that transcript.

## Rebuild after changes

```bash
./build.sh
```

With `./setup-signing.sh` run once, rebuilds keep your meeting capture permissions.

## Tests

```bash
./Tests/run-tests.sh
```

The test suite covers provider choices, meeting timeline offsets, retention, Google Meet bridge
configuration, consent safeguards, transcription structure, and extension syntax.

## Troubleshooting

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
