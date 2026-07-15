#!/bin/bash
set -euo pipefail

title="${1:-E2E Consent UI}"
slug="$(printf '%s' "$title" | tr '[:upper:] ' '[:lower:]-')"
payload="{\"kind\":\"joined\",\"title\":\"$title\",\"url\":\"https://meet.google.com/$slug\"}"
/usr/bin/curl --max-time 2 -sS -X POST http://127.0.0.1:49413/event \
  -H 'Content-Type: application/json' --data "$payload" >/dev/null
# Keep the harness alive long enough for a separate accessibility assertion while the
# production five-second prompt is visible.
sleep 6
