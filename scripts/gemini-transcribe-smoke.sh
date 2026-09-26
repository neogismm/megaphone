#!/usr/bin/env bash
# Send one WAV to gemini-3.5-transcribe with the same request shape
# GeminiTranscriptionService builds, and print the raw response.
#
# Usage: scripts/gemini-transcribe-smoke.sh <file.wav> [verbatim|smart] [language] [term,term,...]
#
# The key comes from GEMINI_API_KEY, else ~/.config/megaphone/gemini-key —
# the same places the app looks. To make a test WAV on a Mac:
#   say -o /tmp/test.wav --data-format=LEI16@16000 "Megaphone uses SwiftUI"
set -euo pipefail

wav="${1:?usage: $0 <file.wav> [verbatim|smart] [language] [term,term,...]}"
mode="${2:-verbatim}"
language="${3:-}"
terms="${4:-}"

key="${GEMINI_API_KEY:-}"
if [ -z "$key" ] && [ -f "$HOME/.config/megaphone/gemini-key" ]; then
  key="$(tr -d '[:space:]' < "$HOME/.config/megaphone/gemini-key")"
fi
[ -n "$key" ] || { echo "No key: set GEMINI_API_KEY or write ~/.config/megaphone/gemini-key" >&2; exit 1; }

json_list() {
  local IFS=','; local out="" item
  for item in $1; do
    [ -n "$item" ] && out="$out${out:+,}\"$item\""
  done
  printf '%s' "$out"
}

config="\"mode\":\"$mode\""
[ -n "$terms" ] && config="$config,\"custom_vocabulary\":[$(json_list "$terms")]"
[ -n "$language" ] && config="$config,\"language_codes\":[$(json_list "$language")]"

body="$(mktemp)"
trap 'rm -f "$body"' EXIT
{
  printf '{"model":"gemini-3.5-transcribe","input":[{"type":"audio","mime_type":"audio/wav","data":"'
  base64 < "$wav" | tr -d '\n'
  printf '"}],"generation_config":{"transcription_config":{%s}},"store":false}' "$config"
} > "$body"

echo "Request: $(wc -c < "$body" | tr -d ' ') bytes, mode=$mode${language:+, language=$language}${terms:+, vocabulary=$terms}" >&2
curl -sS -w '\nHTTP %{http_code} in %{time_total}s\n' \
  -X POST "https://generativelanguage.googleapis.com/v1beta/interactions" \
  -H "x-goog-api-key: $key" \
  -H "Content-Type: application/json" \
  --data-binary @"$body"
