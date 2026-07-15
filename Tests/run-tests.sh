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
    Sources/Murmur/RecordingState.swift \
    Tests/MurmurTests/main.swift \
    -o "$BIN"

"$BIN"

rg -Fq '49_413' Sources/Murmur/MeetBridgeServer.swift
rg -Fq '127.0.0.1:49413' ArcExtension/background.js
rg -Fq '127.0.0.1:49413' ArcExtension/manifest.json
node --check ArcExtension/background.js
node --check ArcExtension/content.js
rg -Fq 'automaticallyGenerateSummary' Sources/Murmur/MeetingCoordinator.swift
rg -Fq 'await llm.isConfigured(provider)' Sources/Murmur/MeetingCoordinator.swift
rg -Fq 'copyButton(meeting.transcript' Sources/Murmur/MeetingDashboard.swift
rg -Fq 'copyButton(message.text' Sources/Murmur/MeetingDashboard.swift
rg -Fq 'Individual remote-speaker diarization is not installed yet' Sources/Murmur/MeetingDashboard.swift
rg -Fq 'recordingOffer' Sources/Murmur/MeetingActivityPanel.swift
rg -Fq 'asyncAfter(deadline: .now() + 5)' Sources/Murmur/AppController.swift
rg -Fq 'onDeclineRecording' Sources/Murmur/MeetingActivityPanel.swift
rg -Fq 'leaveGraceMilliseconds = 15000' ArcExtension/content.js
rg -Fq 'duplicate Meet join ignored' Sources/Murmur/AppController.swift
rg -Fq 'sustained Meet leave confirmed' Sources/Murmur/AppController.swift
rg -Fq 'Delete selected meetings' Sources/Murmur/MeetingDashboard.swift
rg -Fq 'override func copy' Sources/Murmur/MeetingDashboard.swift
rg -Fq 'NSFindPanelAction.showFindPanel' Sources/Murmur/MeetingDashboard.swift
rg -Fq 'Timer.publish(every: 1' Sources/Murmur/MeetingDashboard.swift
rg -Fq 'isStartingCapture' Sources/Murmur/MeetingCoordinator.swift
rg -Fq 'buildApplicationMenu' Sources/Murmur/AppController.swift
rg -Fq 'copyFromApplicationMenu' Sources/Murmur/AppController.swift
rg -Fq 'findFromApplicationMenu' Sources/Murmur/AppController.swift
rg -Fq 'Stop Recording & Transcribe' Sources/Murmur/AppController.swift
rg -Fq 'Stop recording and transcribe' Sources/Murmur/MeetingDashboard.swift
rg -Fq 'start(title: String = "Audio note"' Sources/Murmur/MeetingCoordinator.swift
rg -Fq 'Dictation Recovery' Sources/Murmur/Recorder.swift
rg -Fq 'finalizing safely' Sources/Murmur/AppController.swift
echo "✓ native and Arc bridge ports match"
echo "✓ Arc extension scripts are syntactically valid"
echo "✓ auto-summary, copy controls, and honest diarization status are present"
