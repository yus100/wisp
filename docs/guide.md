# Wisp guide

Everything beyond the [README](../README.md): shortcuts, attachments, slash commands, voice, coding sessions, settings, privacy, and fixes.

## Shortcuts

| Keys | Action |
| --- | --- |
| **⌥ Space**, tap | Show or hide Wisp |
| **⌥ Space**, hold | Push to talk: speak while holding, release to send |
| **⌥ ⇧ Space** | Hands-free voice: sends after a short pause; press again to send now |
| **↩** | Send. Follow-ups stay in the same conversation |
| **⇧ ↩** or **⌥ ↩** | New line |
| **⌘ ↩** | Continue this conversation in Ghostty. With text typed, start a dev session for it instead |
| **⌘ ⇧ A** | Attach a screenshot of the window you were in when you opened Wisp |
| **⌘ O** | Choose files or folders to attach |
| **⌘ V** | Paste text; copied files and images become attachments |
| **↑ ↓**, **Tab** | Move through the `/` suggestions and fill one in (**↩** does too) |
| **⌘ M** | Choose the model and reasoning effort (or click the model chip) |
| **⌘ N** | New conversation |
| **⌘ .** | Stop the answer |
| **⇧ ⌘ C** | Copy the last answer |
| **⌘ ,** | Edit the settings file |
| **esc** | Close, or stop listening |

A conversation survives closing the panel, and an answer keeps streaming while it's closed. When one finishes there, the menu bar icon gets a dot and its menu offers **Show Answer**; macOS also shows a notification if it allows Wisp's (see [Notifications](#notifications)). Coming back to that answer never triggers the idle reset below. After 10 idle minutes the next open starts fresh; the last 20 conversations stay under **Open Recent in Ghostty** in the menu bar.

## Attachments

Anything attached goes with your next question, shown as chips under the input. Remove one with its **×**.

- **The window you were in.** Wisp remembers which app was in front when you opened it. **⌘ ⇧ A**, or **Attach *App* Window** in the paperclip menu, saves a screenshot of that app's front window. The first time, macOS asks for Screen Recording permission; turn Wisp on in System Settings and reopen it.
- **Files and folders.** Copy them in Finder and press **⌘ V** in Wisp, choose them with **Choose Files…** (**⌘ O**) in the paperclip menu, or drag them onto the panel.
- **Images.** Paste an image (a screenshot copied with ⌃ ⇧ ⌘ 4, say) with **⌘ V**.

Wisp sends the paths, and the agent opens the files with its own tools, so attachments work with every model. Screenshots and pasted images are saved in `~/Library/Caches/Wisp/attachments` and deleted after a week (Wisp checks at launch and whenever the panel opens). **⌘ ↩** with only attachments starts a dev session about them.

## Slash commands

Type `/` to see Grok Build's commands, your skills, and your workflows, with the best matches first. **Tab** or **↩** fills in the highlighted one, ready for arguments, and **↩** on a command typed in full runs it. The list comes from Grok Build with each new conversation and is cached, so on a fresh install it appears after your first question.

Commands that only open a view in Grok Build's terminal UI, such as `/context` and `/memory`, have no output in Wisp. Wisp says so; **⌘ ↩** opens the conversation in Ghostty, where they work.

## Voice

Hold **⌥ Space** to talk and let go to send, or press **⌥ ⇧ Space** to dictate hands-free. Hands-free dictation keeps listening through pauses and sends once you have been quiet for 2.5 seconds (`voicePauseSeconds`); press **↩** or the hotkey to send sooner. Speech goes to the speech-to-text service Grok Build's voice mode uses, signed in with your existing Grok login, so there is no key to set up. To use an xAI API key instead, export `XAI_API_KEY` in your shell profile.

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
| `voicePauseSeconds` | `2.5` | Hands-free voice sends once you have been quiet this long; `0` waits for you |
| `ghosttyTarget` | `window` | Open sessions in a new `window` or a new `tab` of the front window |
| `grokPath` | `""` | Path to `grok`; empty searches your login shell's PATH |
| `extraRules` | `""` | Extra instructions for the quick-answer agent |
| `notifyWhenDone` | `true` | Post a notification when an answer finishes while the panel is closed |
| `remoteControl` | `false` | Accept `Wisp ctl` commands beyond show and hide (see [Scripting](#scripting)) |

Hotkeys combine `cmd`, `option`, `ctrl`, and `shift` with a key such as `space`, `k`, `return`, or `f5`. When Wisp can't register one, the panel says so.

## Privacy and safety

- **The agent can do anything you can.** Quick answers run Grok Build with always-approve in your home folder: it reads, writes, and runs commands without asking. Treat what you paste into it, and pages it reads, as you would in any always-approve session.
- **Wisp collects nothing.** Conversations are Grok Build sessions, stored and handled like any other. Audio is sent for transcription only while you dictate.
- **Screenshots are taken only when you ask.** Attaching a window captures that one window, once. Screen Recording permission lets Wisp do this, and macOS may remind you about it from time to time.
- **macOS asks once per kind of access:** the microphone, protected folders (Documents, Desktop, Downloads, other apps' data), Screen Recording, and control of Ghostty. Full Disk Access removes the folder prompts but also gives that access to anything the agent is talked into doing, so leave it off unless the prompts get in your way.
- **Signing.** `make app` signs ad hoc with a requirement on the bundle ID, so your permissions survive rebuilds. The trade-off: another ad-hoc app claiming `com.yus100.wisp` would match them too. Sign with your own certificate if that matters to you.
- **Remote control is off by default.** See [Scripting](#scripting).

### Notifications

macOS usually refuses notifications from ad-hoc-signed apps without asking, so a plain `make install` gets only the menu bar dot. With an Apple Development or Developer ID certificate (`security find-identity -v -p codesigning` lists yours), build with `make install SIGN_IDENTITY="Apple Development: …"` and macOS asks to allow notifications the first time an answer finishes in the background.

## Scripting

The app binary doubles as a remote control for the running copy:

```sh
WISP=~/Applications/Wisp.app/Contents/MacOS/Wisp
$WISP ctl toggle                    # show, hide, toggle: always available
$WISP ctl ask "summarize the newest file in my Downloads"
$WISP ctl attach ~/Desktop/plan.pdf     # goes with the next question
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
| Attaching a window says it needs Screen Recording | Click **Open Settings** in the notice, turn on Wisp, then quit and reopen Wisp; macOS applies the permission on the next launch |
| No `/` suggestions | Ask one question first; the list arrives with the first conversation |
| Anything else | **Show Logs** in the menu: `app.log` is Wisp, `agent.log` is the agent's output |
