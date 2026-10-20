# Development

## Build and run

| Command | What it does |
| --- | --- |
| `make install` | Release build, assemble and sign `build/Wisp.app`, copy it to `~/Applications`, and relaunch |
| `make run` | Same, but launch from `build/` without installing |
| `make test` | Unit tests (`swift test`), about a second |
| `make lint` / `make format` | Check or apply `swift format` (config in `.swift-format`) |
| `make smoke` | End-to-end check against the installed, running app |
| `make icon` | Redraw `Resources/AppIcon.icns` and `docs/assets/icon.png` from `scripts/make-icon.swift` |
| `make screenshots` | Render the README images in `docs/assets` from sample data, offscreen, with the real panel views |

Everything builds with the Xcode Command Line Tools; Xcode itself is not needed. The package targets macOS 14 and Swift 6 language mode.

## Tests

`WispCoreTests` uses Swift Testing and covers the core without mocks where it can:

- **Agent:** `GrokAgentTests` runs `GrokAgent` against `Tests/WispCoreTests/Fixtures/fake-grok-agent.py`, a stand-in that speaks enough ACP to exercise the real process, pipes, framing, ordering, permission and unsupported requests, model switching, `session/load`, and crashes.
- **Voice:** `SpeechToTextStreamTests` runs the WebSocket client against a local Network.framework server that behaves like xAI speech-to-text, including errors and a silent server.
- **Ghostty:** `GhosttyLauncherTests` runs the real `ghostty-grok` in `--dry-run` mode, including the exact heredoc form the agent is told to use.
- **Everything else:** the conversation reducer, transcript stitching, Markdown, config, hotkey parsing (checked against Carbon's key codes), shell-environment parsing, credentials, history, and paths.

## End-to-end smoke test

`scripts/smoke-test.sh` drives the installed app through `Wisp ctl`. It types a question, checks the streamed answer, dictates a follow-up from a `say`-generated WAV (checking that context carries over), switches the model mid-conversation and back, runs a slash command picked from the suggestions, has the agent read an attached file, filters the history and reopens a conversation from it, and checks the panel keys. It needs remote control, which is off by default:

```sh
# in ~/.config/wisp/config.json
"remoteControl": true
```

Turn it off again afterwards. The test costs a few model calls. Clicking another app while it runs hides the panel (by design), so the script re-shows the panel before each key press.

Useful by hand while developing:

```sh
APP=~/Applications/Wisp.app/Contents/MacOS/Wisp
$APP ctl state /tmp/state.json     # panel state, turns, model list, notices
$APP ctl snapshot /tmp/panel.png   # render the panel, no screen-recording permission needed*
$APP ctl attach ~/notes.txt        # attach a file to the next question
$APP ctl type "hello"; $APP ctl key return
$APP ctl history; $APP ctl key down   # the history list (⌘Y)
$APP ctl voice-file question.wav   # 16 kHz mono 16-bit WAV
Resources/ghostty-grok --dry-run --cwd ~/code/app --prompt "fix it"
```

\* A snapshot of the live panel can miss text SwiftUI has already drawn on screen. To check layout and text, add a sample to `Screenshots.swift` and run `make screenshots`, which renders offscreen in full.

## What the tests cannot cover

Some paths need a person at the Mac: the global hotkeys (synthetic key events cannot reach Carbon hotkeys without Accessibility permission), the live microphone, the macOS permission prompts (including Screen Recording for **Attach Window**), dragging files onto the panel, the file picker, notifications (which need a certificate-signed build), and Ghostty actually drawing a window. Ghostty starts a window's shell only once the window is drawn, so the hand-off cannot be checked while the screen is locked. After changing those areas, check them by hand: tap and hold `⌥Space`, dictate with `⌥⇧Space`, press `⌘⇧A` over another app, drag a file from Finder onto the panel, use **Choose Files…**, and press `⌘↩` on a conversation.

## Debugging

- `~/Library/Logs/Wisp/app.log` records launches, agent starts and exits, hotkey problems, and refused `ctl` commands. `agent.log` is grok's stderr.
- **Restart Grok Agent** in the menu starts a fresh agent; quick answers then start a new session.
- Grok Build's own session files (`~/.grok/sessions/%2FUsers%2F<you>/<id>/`) show exactly what the agent saw and did.

## Releasing

Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`, then `make install`. The app reports that version to grok as its ACP client version and shows it in the menu.
