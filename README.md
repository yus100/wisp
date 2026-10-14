# Wisp

A Spotlight-style launcher for Grok on macOS. Press a hotkey, type or say a question, and get a short answer from a real Grok Build agent that can use your files, apps, and shell. When a question turns into real work, one keystroke moves the conversation into a full Grok Build session in Ghostty, or Wisp opens a fresh dev session in the right project for you.

No chat window to find, no session to pick, no terminal to set up first.

## Install

You need macOS 14 or later, the Xcode Command Line Tools (`xcode-select --install`), the [Grok Build CLI](https://x.ai/cli) signed in (`grok login`), and [Ghostty](https://ghostty.org) 1.3 or later for the hand-off.

```sh
git clone git@github.com:yus100/wisp.git
cd wisp
make install    # builds Wisp.app, copies it to ~/Applications, and launches it
```

A sparkle appears in the menu bar. Turn on **Launch at Login** from its menu.

## Use

| Shortcut | What it does |
| --- | --- |
| `⌥Space`, tap | Show or hide the panel |
| `⌥Space`, hold | Push to talk: speak while holding, release to send |
| `⌥⇧Space` | Hands-free voice: sends after a short pause; press again to send now |

In the panel:

| Key | What it does |
| --- | --- |
| `↩` | Send. Follow-ups stay in the same conversation |
| `⇧↩` or `⌥↩` | New line |
| `⌘↩` | Continue this conversation in Ghostty. With text typed, start a dev session for it instead |
| `⌘M` | Choose the model and reasoning effort (or click the model chip) |
| `⌘N` | New conversation |
| `⌘.` | Stop the answer |
| `⇧⌘C` | Copy the last answer |
| `⌘,` | Edit the config |
| `esc` | Close, or stop listening |

A conversation survives closing the panel. After 10 idle minutes the next open starts fresh, and the last 20 conversations stay under **Open Recent in Ghostty** in the menu bar, titled the way Grok Build titles them.

### Voice

Voice uses the speech-to-text service Grok Build's voice mode uses (`wss://api.x.ai/v1/stt`) with your existing Grok login, so there is no key to set up. The first use asks for microphone access. To use an API key instead, export `XAI_API_KEY` in your shell profile.

### Dev sessions in Ghostty

- **`⌘↩` on a conversation** stops any running answer, unloads the session from Wisp, and runs `grok --resume <id>` in a new Ghostty window. The TUI picks up with the full context. If Ghostty can't open, the conversation stays in the panel.
- **Asking for work** ("start a dev session in my website repo to add a blog page") makes the agent find the project directory, write a self-contained brief, and open `grok -- "<brief>"` there.
- The command is typed into a fresh login shell, so grok gets your normal environment, it lands in your shell history, and you are left in the project directory when grok exits.
- The same opener works from any terminal: `~/Applications/Wisp.app/Contents/Resources/ghostty-grok --cwd ~/code/app --prompt "fix the login bug"`. Run it with `--help` for the options.

## Configuration

`~/.config/wisp/config.json` is created on first launch and reloaded as soon as you save it. Every key is optional.

| Key | Default | Meaning |
| --- | --- | --- |
| `hotkey` | `option+space` | Tap to toggle the panel, hold to talk |
| `voiceHotkey` | `option+shift+space` | Hands-free voice |
| `model` | `""` | Model for quick answers (set it with `⌘M`); empty uses your Grok Build default |
| `reasoningEffort` | `low` | `minimal`, `low`, `medium`, `high`, or `xhigh` (set it with `⌘M`); empty uses the model's default |
| `workingDirectory` | `~` | Where quick-answer sessions run |
| `idleResetMinutes` | `10` | Start fresh after this much idle time; `0` never resets |
| `voiceLanguage` | `en` | Speech-to-text language code |
| `voiceSilenceSeconds` | `1.2` | Hands-free voice sends after this much silence; `0` waits for you |
| `ghosttyTarget` | `window` | Open sessions in a new `window` or a new `tab` of the front window |
| `grokPath` | `""` | Path to `grok`; empty searches your login shell's PATH |
| `extraRules` | `""` | Extra instructions for the quick-answer agent |
| `remoteControl` | `false` | Accept `Wisp ctl` commands beyond show and hide (see below) |

Hotkeys combine `cmd`, `option`, `ctrl`, and `shift` with a key such as `space`, `k`, `return`, or `f5`. When Wisp cannot register one, the panel says so.

## Privacy and safety

- **The agent can do anything you can.** Quick-answer sessions run Grok Build with always-approve in your home directory: it reads, writes, and runs commands without asking. Treat what you paste into it, and pages it reads, as you would in any always-approve session.
- **macOS asks once per kind of access:** the microphone, protected folders (Documents, Desktop, Downloads, other apps' data), and Automation for Ghostty. Granting Full Disk Access to Wisp removes the folder prompts, but it also gives that access to anything the agent is talked into doing, so leave it off unless the prompts get in your way.
- **Signing.** `make app` signs ad hoc with a requirement on the bundle ID, so your grants survive rebuilds. The trade-off: another ad-hoc binary claiming `com.yus100.wisp` would match those grants too. Sign with your own certificate if that matters to you.
- **`Wisp ctl` is off by default.** `show`, `hide`, and `toggle` always work. Everything else (ask, voice, reading the panel) needs `"remoteControl": true`, because it lets any process running as you use Wisp's permissions. Files only pass through Wisp's own temporary folder.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| The hotkey does nothing | Another app may be using the same shortcut. Set `hotkey` to something else |
| "Could not find the grok CLI" | Install Grok Build, or set `grokPath` |
| Voice says it needs a login | Run `grok login` in a terminal |
| "Wisp is not allowed to control Ghostty" | Click **Open Settings** in the notice and turn on Ghostty under Wisp |
| Anything else | **Show Logs** in the menu: `app.log` is Wisp, `agent.log` is grok's stderr |

## Development

`make help` lists the targets: `make test` runs the unit tests, `make lint` checks formatting, and `make smoke` drives the installed app end to end. See [docs/development.md](docs/development.md) for the workflow and [docs/architecture.md](docs/architecture.md) for how the pieces fit together.
