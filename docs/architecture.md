# Architecture

Wisp is a thin, always-running shell around Grok Build. It never talks to a model itself: every answer comes from a `grok agent` process, and every conversation is an ordinary Grok Build session. That is what makes the hand-off to the TUI seamless: there is nothing to convert or export.

## Layout

The package has two targets, both built in Swift 6 language mode (strict concurrency).

| Target | What lives there |
| --- | --- |
| `WispCore` | Everything that does not need AppKit: the ACP client and agent process, the conversation reducer, speech-to-text, Ghostty launcher, config, and parsing. Covered by `WispCoreTests`. |
| `Wisp` | The menu-bar app: panel window and SwiftUI views, hotkeys, microphone capture, the menu, and the `ctl` remote control. |

```
Sources/WispCore/
  ACP/            LineFramer, JSON-RPC envelopes, ACPConnection (actor), typed ACP messages
  Agent/          GrokAgent (process + session API), ModelCatalog, QuickAnswerRules
  Conversation/   Conversation (update reducer), SessionHistory, GrokSessionStore
  Voice/          SpeechToText, TranscriptAssembler, RecordedAudio, GrokCredentials
  Ghostty/        GhosttyLauncher
  Config/         WispConfig, HotkeySpec
  Markdown/       MarkdownBlock parser
  Support/        Log, WispPaths, ProcessRunner, ShellEnvironment, withDeadline
Sources/Wisp/
  App/            main, AppDelegate, ConfigStore, HotkeyController, StatusMenuController, RemoteControl, MainMenu,
                  Screenshots (renders the README images)
  Model/          AppModel (coordinator), AgentHost (agent lifecycle)
  Voice/          VoiceController, MicrophoneCapture
  Panel/          PanelController (+Testing), ModelMenu
  Views/          PanelView, InputBar, ConversationView, MarkdownView, FooterView
Resources/        Info.plist, ghostty-grok, AppIcon.icns
docs/assets/      README images (make icon, make screenshots)
```

## A question, end to end

1. **Hotkey.** `HotkeyController` gets key-down from Carbon and the delegate shows the panel immediately. Key-up within 300 ms is a tap; holding longer starts push-to-talk.
2. **Submit.** `AppModel.submit` appends a running `Turn` and asks `AgentHost` for the warm agent. On the first question of a conversation it calls `session/new` in the working directory with always-approve and `QuickAnswerRules` as extra system-prompt rules, then applies the chosen model and effort with `session/set_config_option`.
3. **Stream.** `session/prompt` runs the turn. grok streams `session/update` notifications (text chunks, tool calls, tool updates) and `_x.ai/session_notification` (retry state). `Conversation.apply` folds each into the turn, and SwiftUI re-renders.
4. **Finish.** The `session/prompt` reply carries the stop reason and the model that answered. The reply is handled only after every update that preceded it (see ordering, below), so a turn never ends before its last words.

## The agent (ACP)

`GrokAgent` spawns `grok agent --always-approve stdio` with the user's login-shell environment and speaks the [Agent Client Protocol](https://agentclientprotocol.com): newline-delimited JSON-RPC 2.0 over stdin and stdout.

- **Framing.** `LineFramer` splits on `\n` bytes only. JSON may contain raw U+2028 and U+2029, which Foundation's line iterators treat as line breaks.
- **Ordering.** One reader task frames stdout and hands each message to `ACPConnection.receive`. Replies resume their awaiting `request`; notifications and agent requests come back to the reader, which handles them on the main actor before reading the next line. Updates therefore apply strictly in order, and always before the reply that follows them.
- **Typed messages.** `ACPMessages.swift` holds the subset Wisp uses. Decoding is lenient (unknown fields ignored, unknown update kinds become `.other`), so newer grok versions do not break the panel.
- **Agent requests.** Permission requests should not happen under always-approve; if one does, Wisp answers `allow_once`, never an "always" option that would save a rule into the user's own grok settings. Anything else gets a JSON-RPC "method not found".
- **Cancellation.** Cancelling the task awaiting a request abandons it (a late reply is ignored), which is what lets `withDeadline` time out a request.
- **Lifecycle.** `initialize` has a 30-second deadline, after which the process is killed; its reply carries the model list (`ModelCatalog`). Starts carry a generation number, so a restart stops an agent that is still starting and discards the superseded start. If the process dies, pending requests fail with `ACPError.disconnected`, `AgentHost` drops it, and `AppModel` re-attaches the conversation's session on a fresh agent with `session/load`, so follow-ups keep their context. SIGPIPE is ignored so a write to a dead agent fails instead of killing Wisp.

`AgentHost` resolves the login-shell environment once (`$SHELL -ilc 'env -0'`, behind a marker so profile output is ignored) and shares it: launchd gives apps a minimal PATH, and the agent needs the same tools a terminal would have.

## Conversations

- Each conversation has an identity. Work that outlives its conversation (a session still being created when you press ⌘N, a prompt that returns late) checks it and leaves the new conversation alone; a session created for a conversation that is already gone is closed.
- ⌘. before the turn's session exists is remembered and applied as soon as it does.
- `session/load` replays the session's history as updates. Re-attaching ignores updates until the load returns (they all arrive before its reply), and follow-up questions wait for the re-attach to finish.

## Voice

```
MicrophoneCapture ──AsyncStream<Data>──▶ SpeechToText.transcribe ──events──▶ TranscriptAssembler ──▶ input field
 (AVAudioEngine, 16 kHz mono Int16)       (wss://api.x.ai/v1/stt)
```

- The microphone opens as soon as dictation begins; audio waits in the stream's buffer while the bearer token is fetched and the socket connects, so the first words are never lost.
- Audio passes through a forwarding stage in `VoiceController` on its way to the socket. It drives the level meter and `EndOfSpeechDetector`, and finishing ends it, so recordings stop exactly like the microphone.
- Hands-free dictation ends after `voicePauseSeconds` of real quiet: no voice in the audio (measured against an adaptive noise floor) and no new live transcript text. The server's `speech_final` comes after only 400 ms of quiet and its next transcript a second after speech resumes, so timing on transcript events alone cut dictations off at ordinary thinking pauses (issue #1).
- Ending the audio stream (key released, Return, or the end of a pause) makes `SpeechToText` send `audio.done`; the server answers with the final transcript and `transcript.done`. Connect and final-transcript timeouts close the socket, because `URLSessionWebSocketTask.receive()` ignores task cancellation.
- `TranscriptAssembler` mirrors Grok Build's stitching: chunks marked `is_final` lock into a running preview, and committed text comes only from `speech_final`, which re-transcribes the whole utterance cleanly.
- `VoiceController` is a small state machine (idle, starting, listening, finishing). Each dictation keeps its transcript local and checks a generation token after every await (a cancelled stream ends its loop without throwing), so a cancelled dictation's leftovers never reach the input or a newer dictation. The no-speech timer starts once the stream is ready, so a slow token refresh does not count as silence, and its message says whether the microphone heard sound at all.
- `GrokCredentials` reads the OAuth access token grok keeps in `auth.json` (about 15 minutes long). When it is stale, Wisp runs `grok models`, which makes grok refresh and rewrite the token under its own lock; Wisp never handles the refresh token.

## Ghostty hand-off

`ghostty-grok` (bash plus Ghostty 1.3's AppleScript dictionary) is the only code that opens terminals. The app runs it through `GhosttyLauncher`, and the agent runs it directly when asked to start a dev session, so both paths behave the same.

- It creates a surface configuration with the working directory, an environment variable carrying the prompt, and *initial input* that types `grok [--resume <id>] [-- "$WISP_PROMPT"]` into the user's login shell. Typing into the shell (rather than replacing it with a command) gives grok the normal environment and shell integration, records the command in history, and leaves a shell in the project when grok exits.
- What gets typed is fixed text, the grok path (shell-quoted), and a validated session ID. The prompt travels in the environment and follows `--`, so quotes, newlines, `$()`, and leading dashes are all safe.
- The target (new window or tab) comes from `--tab`/`--window`, else `$WISP_GHOSTTY_TARGET`, else `ghosttyTarget` read from Wisp's config file, so sessions the agent opens follow the setting without an agent restart.
- On a cold launch it closes the window Ghostty opens on its own, so only the session window remains.
- Exit codes (3: Ghostty missing or older than 1.3, 4: Automation denied, 5: other) become `GhosttyLauncher.Failure`, which the panel shows with an **Open Settings** button where that helps.
- On `⌘↩`, `AppModel` stops a running answer, unloads the session (`session/close`) so the TUI is its only writer, and opens Ghostty. If that fails, it re-attaches the session with `session/load`.

## Panel

`WispPanel` is a borderless, non-activating `NSPanel`: it takes keyboard focus while the app you were using stays frontmost, and it hides when you click elsewhere (hands-free dictation keeps running). SwiftUI reports the content height and `PanelController` resizes the window on the next run-loop turn, keeping the top edge fixed; resizing inside a layout pass leaves the frame and content out of sync. A local key monitor handles the panel shortcuts, leaves Return alone while an input method is composing, and a hidden main menu supplies the standard editing shortcuts.

## Configuration and state

| What | Where |
| --- | --- |
| Settings | `~/.config/wisp/config.json`, watched with dispatch sources and applied live. Reloads are read-only (a file briefly missing mid-save changes nothing), a file with errors is never overwritten, and saves go through a symlinked config to its target |
| Recent conversations | `~/Library/Application Support/Wisp/history.json`; titles come from grok's `summary.json` |
| Logs | `~/Library/Logs/Wisp/app.log` (Wisp) and `agent.log` (grok's stderr); each starts afresh past 5 MB, checked at launch and agent start |
| Sessions | Wherever grok keeps them (`~/.grok/sessions`), like any other Grok Build session |

## Remote control

`Wisp ctl <command>` posts a distributed notification that `ControlServer` acts on. `show`, `hide`, and `toggle` always work; everything else requires `"remoteControl": true`, because it would let any process running as the user drive the always-approve agent and the microphone through Wisp's permissions. File arguments pass through Wisp's own temporary folder, and the `ctl` client copies them in and out with its own permissions; staged recordings are deleted once read (or refused), and anything left there over a minute is cleared. The smoke test and the panel snapshots in development are built on this.
