# Wisp

A Spotlight-style launcher for Grok on macOS. Press a hotkey, type or say a question, and get a short answer from a real Grok Build agent that has full access to your files and shell. When a question turns into real work, one keystroke moves the conversation into a full Grok Build session in Ghostty, or you can ask it to start a fresh dev session in the right project.

No chat app to open, no session to pick, no terminal to set up first.

## Install

Requirements: macOS 14 or later, Xcode Command Line Tools, the [Grok Build CLI](https://x.ai/cli) signed in (`grok login`), and Ghostty 1.3 or later for the hand-off.

```sh
make install   # builds Wisp.app, copies it to ~/Applications, and launches it
```

A sparkle icon appears in the menu bar. Turn on **Launch at Login** from that menu.

## Use

| Hotkey | What it does |
| --- | --- |
| `⌥Space` (tap) | Show or hide the panel |
| `⌥Space` (hold) | Push to talk: speak while holding, release to send |
| `⌥⇧Space` | Hands-free voice: sends after you pause; press again to send now |

In the panel:

| Key | What it does |
| --- | --- |
| `↩` | Send (follow-ups stay in the same conversation) |
| `⇧↩` | New line |
| `⌘↩` | Continue this conversation in Ghostty. With text typed, start a dev session for that task instead |
| `⌘N` | New conversation |
| `⌘M` | Pick the model and reasoning effort (or click the model chip next to the mic) |
| `⌘.` | Stop the current answer |
| `⇧⌘C` | Copy the last answer |
| `⌘,` | Edit the config |
| `esc` | Close (or stop listening) |

The model you pick applies right away, even mid-conversation, and is saved for next time. Quick answers default to your Grok Build model with low reasoning effort.

The conversation survives closing the panel. After 10 idle minutes the next open starts fresh; the last 20 conversations stay under **Open Recent in Ghostty** in the menu bar.

### Dev sessions

- `⌘↩` on a conversation closes it here and runs `grok --resume <id>` in a new Ghostty window, so the TUI picks up with the full context.
- Saying or typing something like "start a dev session in my website repo to add a blog page" makes the agent find the project directory, write a self-contained brief, and open `grok "<brief>"` there in Ghostty.
- `ghostty-grok` (in `Resources/`, and inside the app bundle) does the opening and works from any shell: `ghostty-grok --cwd ~/Documents/app --prompt "fix the login bug"` or `ghostty-grok --resume <session-id>`. The command is typed into your normal login shell, so you land in that directory when grok exits.

### Voice

Voice uses the same streaming speech-to-text endpoint as Grok Build (`wss://api.x.ai/v1/stt`) with your existing Grok login, so there is no extra key to set up. The first use asks for microphone access. Set `XAI_API_KEY` in your shell profile to use an API key instead.

## Config

`~/.config/wisp/config.json` is created on first launch. Edits apply the next time the panel opens.

| Key | Default | Meaning |
| --- | --- | --- |
| `hotkey` | `option+space` | Tap to toggle, hold to talk |
| `voiceHotkey` | `option+shift+space` | Hands-free voice |
| `model` | `""` | Model for quick answers (set by `⌘M`); empty uses your Grok Build default |
| `reasoningEffort` | `low` | `minimal`, `low`, `medium`, `high`, `xhigh` (set by `⌘M`), or empty for your default |
| `workingDirectory` | `~` | Where quick-answer sessions run |
| `idleResetMinutes` | `10` | Start fresh after this much idle time; `0` never resets |
| `voiceLanguage` | `en` | Speech-to-text language code |
| `voiceSilenceSeconds` | `1.2` | Hands-free mode sends after this much silence; `0` waits for you |
| `ghosttyTarget` | `window` | Open sessions in a new `window` or `tab` |
| `grokPath` | `""` | Path to `grok`; empty searches your shell's PATH |
| `extraRules` | `""` | Extra instructions for the quick-answer agent |

Hotkeys accept `cmd`, `option`, `ctrl`, `shift` plus a key such as `space`, `k`, `return`, or `f5`.

## Permissions

Quick-answer sessions run with always-approve in your home directory, so the agent can read, write, and run anything you can. macOS still asks once per protected area:

- **Microphone** on first voice use.
- **Documents, Desktop, Downloads** (and other apps' data) the first time the agent touches them. To skip these prompts, add Wisp to System Settings › Privacy & Security › Full Disk Access.
- **Automation › Ghostty** the first time a session opens in Ghostty.

The build signs the app ad hoc with a designated requirement on its bundle ID, so these grants survive rebuilds.

## How it works

- The app keeps one `grok agent --always-approve stdio` process warm and talks to it over ACP (JSON-RPC on stdin/stdout). Each conversation is a normal Grok Build session (`session/new` in your home directory), so it has your models, MCP servers, skills, and memory, and it is saved where `grok --resume` can find it.
- The agent gets extra rules: answer briefly, use tools freely, and open dev work in Ghostty through `ghostty-grok`.
- The agent runs with your login shell's environment, resolved once with `zsh -ilc`, so Homebrew and other tools are on PATH.
- The panel is a non-activating `NSPanel` hosting SwiftUI. Global hotkeys use Carbon's `RegisterEventHotKey`, which needs no Accessibility permission.
- Voice captures 16 kHz mono PCM with `AVAudioEngine` and streams it to xAI speech-to-text. The access token comes from `~/.grok/auth.json`; when it is stale, the app runs `grok models` so grok refreshes it.

## Scripting and testing

The app binary doubles as a remote control for the running instance:

```sh
APP=~/Applications/Wisp.app/Contents/MacOS/Wisp
$APP ctl toggle                 # or show, hide, voice, new, ghostty
$APP ctl model grok-4.7         # or: ctl effort medium
$APP ctl ask "what's on my calendar today?"
$APP ctl state /tmp/state.json  # panel state as JSON
$APP ctl snapshot /tmp/p.png    # render the panel
```

`scripts/smoke-test.sh` drives typing, an answer, voice from a synthesized WAV, and the panel keys against the installed app. Logs are in `~/Library/Logs/Wisp/` (`app.log`, plus the agent's stderr in `agent.log`).
