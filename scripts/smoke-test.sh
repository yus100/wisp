#!/bin/bash
# End-to-end check of the installed, running app: typing, a streamed answer, voice from a synthesized
# WAV, model switching, and the panel keys. Costs a few model calls.
#
# Needs "remoteControl": true in ~/.config/wisp/config.json (Wisp ctl is off by default).
set -euo pipefail

CTL="${WISP_APP:-$HOME/Applications/Wisp.app}/Contents/MacOS/Wisp"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/wisp-smoke.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

pass() { printf '  ok  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  exit 1
}
state() { "$CTL" ctl state "$OUT/state.json" || fail "no state; is remoteControl on?"; }
field() { python3 -c "import json,sys; d=json.load(open('$OUT/state.json')); print(eval(sys.argv[1]))" "$1"; }
# Clicking another app hides the panel (as Spotlight does), so bring it back before each key press.
press() {
  "$CTL" ctl show
  sleep 0.2
  "$CTL" ctl key "$1"
}
wait_idle() {
  for _ in $(seq 1 90); do
    sleep 1
    state
    [ "$(field "d['isWorking']")" = "False" ] && [ "$(field "d['voice']['state']")" = "idle" ] && return 0
  done
  fail "timed out waiting for an answer"
}

pgrep -x Wisp >/dev/null || fail "Wisp is not running (make install)"
state
original_model="$(python3 -c "import json; print(json.load(open('$HOME/.config/wisp/config.json')).get('model', ''))")"

press cmd+n
sleep 0.3
"$CTL" ctl type "what is 6*7? reply with only the number"
sleep 0.3
state
[ "$(field "d['input']")" = "what is 6*7? reply with only the number" ] && pass "typing reaches the input" || fail "typing: $(field "d['input']")"
press return
wait_idle
[[ "$(field "d['turns'][-1]['answer']")" == *42* ]] && pass "answer streams back" || fail "answer: $(field "d['turns'][-1]")"
"$CTL" ctl snapshot "$OUT/answer.png" && [ -s "$OUT/answer.png" ] && pass "panel renders to PNG"

say -o "$OUT/question.wav" --data-format=LEI16@16000 "And what is that number times two? Only the number."
"$CTL" ctl voice-file "$OUT/question.wav"
wait_idle
query="$(field "d['turns'][-1]['query']")"
[[ "$query" == *[Tt]imes* ]] && pass "voice transcript sent: $query" || fail "voice query: $query"
[[ "$(field "d['turns'][-1]['answer']")" == *84* ]] && pass "follow-up keeps context" || fail "follow-up: $(field "d['turns'][-1]")"

first_other="$(field "[m for m in d['models'] if m != '$original_model'][0]")"
"$CTL" ctl model "$first_other"
sleep 0.5
"$CTL" ctl ask "reply with just: pong"
wait_idle
[ "$(field "d['turns'][-1]['model']")" = "$first_other" ] && pass "model switch applies mid-conversation ($first_other)" || fail "model: $(field "d['turns'][-1]")"
"$CTL" ctl model "$original_model"

press shift+return
"$CTL" ctl type "x"
sleep 0.3
state
[ "$(field "d['input']")" = $'\nx' ] && pass "shift+return inserts a newline" || fail "newline: $(field "repr(d['input'])")"
press cmd+n
sleep 0.3
state
[ "$(field "len(d['turns'])")" = "0" ] && [ -z "$(field "d['input']")" ] && pass "⌘N starts over" || fail "new conversation"
press escape
sleep 0.3
state
[ "$(field "d['visible']")" = "False" ] && pass "esc hides the panel" || fail "esc"
echo "all checks passed"
