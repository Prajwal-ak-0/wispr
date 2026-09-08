#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
CACHE_DIR="${TMPDIR:-/tmp}/murmur-test-module-cache"
BIN="${TMPDIR:-/tmp}/murmur-tests"

swiftc \
    -module-cache-path "$CACHE_DIR" \
    -swift-version 5 \
    -target arm64-apple-macos26.0 \
    Sources/Murmur/Config.swift \
    Sources/Murmur/Log.swift \
    Sources/Murmur/MeetingModels.swift \
    Tests/MurmurTests/main.swift \
    -o "$BIN"

"$BIN"

grep -Fq '49_413' Sources/Murmur/MeetBridgeServer.swift
grep -Fq '127.0.0.1:49413' ArcExtension/background.js
grep -Fq '127.0.0.1:49413' ArcExtension/manifest.json
node --check ArcExtension/background.js
node --check ArcExtension/content.js
grep -Fq 'automaticallyGenerateSummary' Sources/Murmur/MeetingCoordinator.swift
grep -Fq 'await llm.isConfigured(provider)' Sources/Murmur/MeetingCoordinator.swift
grep -Fq 'copyButton(meeting.transcript' Sources/Murmur/MeetingDashboard.swift
grep -Fq 'copyButton(message.text' Sources/Murmur/MeetingDashboard.swift
grep -Fq 'StructuredTranscriptView(transcript: structured)' Sources/Murmur/MeetingDashboard.swift
grep -Fq 'MeetingTranscriptionEngine.allCases' Sources/Murmur/MeetingDashboard.swift
grep -Fq 'transcribeSliceCompletely' Sources/Murmur/MeetingGeminiTranscriber.swift
grep -Fq 'falling back on-device' Sources/Murmur/MeetingGeminiTranscriber.swift
grep -Fq 'v1beta1' Sources/Murmur/MeetingGeminiTranscriber.swift
grep -Fq 'libmp3lame' Sources/Murmur/MeetingAudioExport.swift
grep -Fq 'recordingOffer' Sources/Murmur/MeetingActivityPanel.swift
grep -Fq 'asyncAfter(deadline: .now() + 5)' Sources/Murmur/AppController.swift
grep -Fq 'onDeclineRecording' Sources/Murmur/MeetingActivityPanel.swift
grep -Fq 'leaveGraceMilliseconds = 15000' ArcExtension/content.js
grep -Fq 'duplicate Meet join ignored' Sources/Murmur/AppController.swift
grep -Fq 'sustained Meet leave confirmed' Sources/Murmur/AppController.swift
grep -Fq 'Delete selected meetings' Sources/Murmur/MeetingDashboard.swift
grep -Fq 'override func copy' Sources/Murmur/MeetingDashboard.swift
grep -Fq 'NSFindPanelAction.showFindPanel' Sources/Murmur/MeetingDashboard.swift
grep -Fq 'Timer.publish(every: 1' Sources/Murmur/MeetingDashboard.swift
grep -Fq 'isStartingCapture' Sources/Murmur/MeetingCoordinator.swift
grep -Fq 'buildApplicationMenu' Sources/Murmur/AppController.swift
grep -Fq 'copyFromApplicationMenu' Sources/Murmur/AppController.swift
grep -Fq 'findFromApplicationMenu' Sources/Murmur/AppController.swift
grep -Fq 'Stop Recording & Transcribe' Sources/Murmur/AppController.swift
grep -Fq 'Stop recording and transcribe' Sources/Murmur/MeetingDashboard.swift
grep -Fq 'start(title: String = "Audio note"' Sources/Murmur/MeetingCoordinator.swift
if grep -R -E 'CGEvent\.tapCreate|CGRequestListenEventAccess|AXIsProcessTrusted|HotkeyMonitor|push-to-talk|hold fn' \
    Sources/Murmur >/dev/null; then
    echo "✗ meeting-only Murmur must not contain global keyboard monitoring" >&2
    exit 1
fi
test ! -e Sources/Murmur/Hotkeys.swift
echo "✓ native and Arc bridge ports match"
echo "✓ Arc extension scripts are syntactically valid"
echo "✓ auto-summary, copy controls, and honest diarization status are present"
echo "✓ meeting-only build contains no global keyboard monitoring"
