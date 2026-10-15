#!/bin/bash
# End-to-end check of the installed, running app: typing, a streamed answer, voice from a synthesized
# WAV, model switching, and the panel keys. Costs a few model calls.
#
# Needs "remoteControl": true in ~/.config/wisp/config.json (Wisp ctl is off by default).
set -euo pipefail

CTL="${WISP_APP:-$HOME/Applications/Wisp.app}/Contents/MacOS/Wisp"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/wisp-smoke.XXXXXX")"
original_model=""
restore_model=false
cleanup() {
  $restore_model && "$CTL" ctl model "$original_model"
  rm -rf "$OUT"
}
trap cleanup EXIT

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
restore_model=true

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

# Issue #1: a thinking pause must not end a hands-free dictation; quiet afterwards sends it.
say -o "$OUT/part1.wav" --data-format=LEI16@16000 "Remember the word pineapple."
say -o "$OUT/part2.wav" --data-format=LEI16@16000 "And also the word volcano."
python3 - "$OUT" <<'PY'
import struct, sys
out = sys.argv[1]
def pcm(path):
    data = open(path, "rb").read()
    return data[data.index(b"data") + 8:]
body = pcm(f"{out}/part1.wav") + b"\0\0" * 32000 + pcm(f"{out}/part2.wav") + b"\0\0" * 96000  # 2 s pause, 6 s quiet
header = b"RIFF" + struct.pack("<I", 36 + len(body)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16)
open(f"{out}/paused.wav", "wb").write(header + b"data" + struct.pack("<I", len(body)) + body)
PY
press cmd+n
sleep 0.3
"$CTL" ctl voice-file "$OUT/paused.wav"
wait_idle
query="$(field "d['turns'][-1]['query']")"
[[ "$query" == *[Pp]ineapple* && "$query" == *[Vv]olcano* ]] && pass "a 2 s pause does not cut a dictation short" || fail "paused dictation sent: $query"

first_other="$(field "[m for m in d['models'] if m != '$original_model'][0]")"
"$CTL" ctl model "$first_other"
sleep 0.5
"$CTL" ctl ask "reply with just: pong"
wait_idle
[ "$(field "d['turns'][-1]['model']")" = "$first_other" ] && pass "model switch applies mid-conversation ($first_other)" || fail "model: $(field "d['turns'][-1]")"

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
