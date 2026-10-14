#!/bin/bash
# End-to-end check against the installed, running app: typing, a quick answer, voice from a
# synthesized WAV, and a new conversation. Costs a couple of model calls.
set -euo pipefail

CTL="${WISP_APP:-$HOME/Applications/Wisp.app}/Contents/MacOS/Wisp"
OUT="${TMPDIR:-/tmp}/wisp-smoke"
mkdir -p "$OUT"
pass() { printf '  ok  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; exit 1; }
field() { python3 -c "import json,sys; d=json.load(open('$OUT/state.json')); print(eval(sys.argv[1]))" "$1"; }
state() { "$CTL" ctl state "$OUT/state.json"; }
# Clicking another app hides the panel (as Spotlight does), so bring it back before each key press.
press() { "$CTL" ctl show; sleep 0.2; "$CTL" ctl key "$1"; }
wait_idle() {
  for _ in $(seq 1 60); do
    sleep 1; state
    [ "$(field "d['isWorking']")" = "False" ] && [ "$(field "d['voice']['active']")" = "False" ] && return 0
  done
  fail "timed out waiting for an answer"
}

pgrep -x Wisp >/dev/null || fail "Wisp is not running (make install)"

"$CTL" ctl show; sleep 0.3
press cmd+n; sleep 0.3
"$CTL" ctl type "what is 6*7? reply with only the number"; sleep 0.3
state; [ "$(field "d['input']")" = "what is 6*7? reply with only the number" ] && pass "typing reaches the input" || fail "typing"
"$CTL" ctl key return
wait_idle
[[ "$(field "d['turns'][-1]['answer']")" == *42* ]] && pass "quick answer streams back" || fail "answer: $(field "d['turns'][-1]")"
"$CTL" ctl snapshot "$OUT/answer.png" && pass "snapshot at $OUT/answer.png"

say -o "$OUT/question.wav" --data-format=LEI16@16000 "What is the capital of France? Answer in one word."
"$CTL" ctl voice-file "$OUT/question.wav"
wait_idle
query="$(field "d['turns'][-1]['query']")"
[[ "$query" == *[Cc]apital* ]] && pass "voice transcript sent: $query" || fail "voice query: $query"
[[ "$(field "d['turns'][-1]['answer']")" == *Paris* ]] && pass "voice follow-up answered" || fail "voice answer"

press cmd+n; sleep 0.3; state
[ "$(field "len(d['turns'])")" = "0" ] && pass "⌘N clears the conversation" || fail "new conversation"
press escape; sleep 0.3; state
[ "$(field "d['visible']")" = "False" ] && pass "esc hides the panel" || fail "esc"
echo "all checks passed"
