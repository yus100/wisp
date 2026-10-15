# Wisp guide

Everything beyond the [README](../README.md): shortcuts, voice, coding sessions, settings, privacy, and fixes.

## Shortcuts

| Keys | Action |
| --- | --- |
| **⌥ Space**, tap | Show or hide Wisp |
| **⌥ Space**, hold | Push to talk: speak while holding, release to send |
| **⌥ ⇧ Space** | Hands-free voice: sends after a short pause; press again to send now |
| **↩** | Send. Follow-ups stay in the same conversation |
| **⇧ ↩** or **⌥ ↩** | New line |
| **⌘ ↩** | Continue this conversation in Ghostty. With text typed, start a dev session for it instead |
| **⌘ M** | Choose the model and reasoning effort (or click the model chip) |
| **⌘ N** | New conversation |
| **⌘ .** | Stop the answer |
| **⇧ ⌘ C** | Copy the last answer |
| **⌘ ,** | Edit the settings file |
| **esc** | Close, or stop listening |

A conversation survives closing the panel. After 10 idle minutes the next open starts fresh; the last 20 conversations stay under **Open Recent in Ghostty** in the menu bar.

## Voice

Hold **⌥ Space** to talk and let go to send, or press **⌥ ⇧ Space** to dictate hands-free. Speech goes to the speech-to-text service Grok Build's voice mode uses, signed in with your existing Grok login, so there is no key to set up. To use an xAI API key instead, export `XAI_API_KEY` in your shell profile.

## Coding sessions in Ghostty

- **⌘ ↩ on a conversation** stops any running answer and resumes the same session in Ghostty (`grok --resume <id>`), so the coding agent has everything said so far. If Ghostty can't open, the conversation stays in Wisp.
- **Ask for work** ("start a dev session in my website repo to add a blog page") and the agent finds the project, writes a self-contained brief, and opens a fresh session there.
- The command is typed into a new login shell, so the session has your usual environment, it lands in your shell history, and you are left in the project folder when it ends.
- The opener works from any terminal too:

  ```sh
  ~/Applications/Wisp.app/Contents/Resources/ghostty-grok --cwd ~/code/app --prompt "fix the login bug"
  ```

  Run it with `--help` for the options.

## Settings

`~/.config/wisp/config.json` is created on first launch and applies as soon as you save it. Every key is optional.

| Key | Default | Meaning |
| --- | --- | --- |
| `hotkey` | `option+space` | Tap to toggle Wisp, hold to talk |
| `voiceHotkey` | `option+shift+space` | Hands-free voice |
| `model` | `""` | Model for quick answers (set it with ⌘ M); empty uses your Grok Build default |
| `reasoningEffort` | `low` | `minimal`, `low`, `medium`, `high`, or `xhigh` (set it with ⌘ M); empty uses the model's default |
| `workingDirectory` | `~` | Folder quick answers run in |
| `idleResetMinutes` | `10` | Start fresh after this much idle time; `0` never resets |
| `voiceLanguage` | `en` | Speech-to-text language code |
| `voiceSilenceSeconds` | `1.2` | Hands-free voice sends after this much silence; `0` waits for you |
| `ghosttyTarget` | `window` | Open sessions in a new `window` or a new `tab` of the front window |
| `grokPath` | `""` | Path to `grok`; empty searches your login shell's PATH |
| `extraRules` | `""` | Extra instructions for the quick-answer agent |
| `remoteControl` | `false` | Accept `Wisp ctl` commands beyond show and hide (see [Scripting](#scripting)) |

Hotkeys combine `cmd`, `option`, `ctrl`, and `shift` with a key such as `space`, `k`, `return`, or `f5`. When Wisp can't register one, the panel says so.

## Privacy and safety

- **The agent can do anything you can.** Quick answers run Grok Build with always-approve in your home folder: it reads, writes, and runs commands without asking. Treat what you paste into it, and pages it reads, as you would in any always-approve session.
- **Wisp collects nothing.** Conversations are Grok Build sessions, stored and handled like any other. Audio is sent for transcription only while you dictate.
- **macOS asks once per kind of access:** the microphone, protected folders (Documents, Desktop, Downloads, other apps' data), and control of Ghostty. Full Disk Access removes the folder prompts but also gives that access to anything the agent is talked into doing, so leave it off unless the prompts get in your way.
- **Signing.** `make app` signs ad hoc with a requirement on the bundle ID, so your permissions survive rebuilds. The trade-off: another ad-hoc app claiming `com.yus100.wisp` would match them too. Sign with your own certificate if that matters to you.
- **Remote control is off by default.** See [Scripting](#scripting).

## Scripting

The app binary doubles as a remote control for the running copy:

```sh
WISP=~/Applications/Wisp.app/Contents/MacOS/Wisp
$WISP ctl toggle                    # show, hide, toggle: always available
$WISP ctl ask "summarize the newest file in my Downloads"
$WISP ctl state /tmp/state.json     # the panel's state as JSON
$WISP ctl help                      # every command
```

Everything except show, hide, and toggle needs `"remoteControl": true`, because it lets any program running as you use Wisp's permissions through the agent.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| The hotkey does nothing | Another app may use the same shortcut. Set `hotkey` to something else |
| "Could not find the grok CLI" | Install [Grok Build](https://x.ai/cli), or set `grokPath` |
| Voice says it needs a login | Run `grok login` in a terminal |
| "Wisp is not allowed to control Ghostty" | Click **Open Settings** in the notice and turn on Ghostty under Wisp |
| Anything else | **Show Logs** in the menu: `app.log` is Wisp, `agent.log` is the agent's output |
