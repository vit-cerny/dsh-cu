# dsh-cu

Windows computer use for agents. Read the screen, click, type, and open apps
from a single command, with any model you like.

- **No dependencies.** Node plus the PowerShell that ships with Windows.
- **No resident process.** Each action starts, does its job, and exits.
- **Any model.** TypeSafe Jev, an OpenAI-compatible endpoint, the model your
  DSH session is already running, or no model at all.
- **Multi-monitor aware.** Pin it to one monitor, or let it use all of them.
- **Stays out of your way.** Background mode never steals the foreground window.

```
npm install -g vit-cerny/dsh-cu     # or clone and run it in place
dsh-cu start "notepad"
dsh-cu run "open notepad and type hello world into it"
```

## Why this exists

Windows UI Automation, OCR and screen capture are built into Windows, but each
one has a sharp edge: UI Automation trees are often empty on Electron and
canvas apps, OCR needs coordinates converted back to physical pixels, and
`SendInput` silently does nothing when the struct is the wrong size. This wraps
those primitives behind one small CLI and a single JSON action protocol, so an
agent can drive the desktop without learning any of that.

## Requirements

- Windows 10 or 11.
- Node.js 18 or newer.
- PowerShell 5.1 (included with Windows).

Nothing else. OCR uses the Windows language pack you already have.

## Install

```powershell
git clone https://github.com/vit-cerny/dsh-cu
cd dsh-cu
node bin/dsh-cu.mjs help
```

Or link it onto your PATH:

```powershell
npm link
dsh-cu help
```

Check it works before letting it touch anything:

```powershell
dsh-cu monitors
dsh-cu windows
```

## Commands

### Look

```powershell
dsh-cu monitors                    # monitor layout and work areas
dsh-cu windows                     # visible windows, with process and monitor
dsh-cu windows --monitor 2         # only windows on monitor 2
dsh-cu shot --monitor 2            # PNG of monitor 2
dsh-cu shot --window Notepad       # PNG of one window
dsh-cu ocr --monitor 2             # text plus screen coordinates
dsh-cu ocr --window Notepad
dsh-cu read --window Notepad       # read a Win32 edit control directly
```

`ocr` returns every recognised word with absolute screen coordinates, so you can
feed those straight back into `act click`.

### Act

```powershell
dsh-cu act click --x 500 --y 300
dsh-cu act click --x 500 --y 300 --double
dsh-cu act click --x 500 --y 300 --button right
dsh-cu act type  --text "hello"
dsh-cu act type  --window Notepad --text "hello"
dsh-cu act key   --keys win
dsh-cu act key   --keys ctrl,s
dsh-cu act focus --window Notepad
dsh-cu act scroll --delta -480
```

`type` refuses to run when it cannot bring the target window forward. Typing
blind would land your text in whatever window happens to be in front, which is
how a stray message gets sent to the wrong person.

### Open apps and files

```powershell
dsh-cu start "notepad"                     # Start menu, type, Enter
dsh-cu start "Task Manager"
dsh-cu open "C:\Users\me\notes.txt"        # default handler
dsh-cu open "https://example.com"
```

`start` drives the real Start menu, which is the only reliable way to reach
apps that have no fixed path. `open` uses ShellExecute and also works for files
that are not indexed, so the Start menu cannot find them.

### Arrange windows

```powershell
dsh-cu fit  --window Discord --monitor 2   # fit inside monitor 2, clear of the taskbar
dsh-cu move --window Discord --x 100 --y 100 --width 1200 --height 800
```

`fit` exists because windows get dragged partly off-screen, which makes their
controls impossible to click and impossible to capture. Run it before a task
that has to click something near the bottom of a window.

## The agent loop

`run` observes the screen, asks the model what to do, acts, and repeats until
the model reports the goal is met.

```powershell
dsh-cu run "open notepad and type hello world into it" --steps 8
dsh-cu run "open notepad and type hello" --dry-run     # plan only, change nothing
```

It stops at `maxSteps` (default 10) and returns the full action history, so you
can see exactly what it did.

### Choosing the model

Set it in `cu.config.json`, or override per call with environment variables.

```powershell
$env:CU_PROVIDER = "session"
dsh-cu brain                     # shows the resolved model and tests it
```

| `provider` | What it means |
|---|---|
| `none` | No model. Every command except `run` still works, so you can drive it yourself. |
| `session` | Reuse the model your DSH session is already running. Reads the DSH profile, credential store and usage ledger. |
| `typesafe` | TypeSafe Jev, the decision API behind jev. Needs `TYPESAFE_API_KEY`. |
| `openai` | Any OpenAI-compatible endpoint. Set `baseURL` and `model`. |

Environment variables always win over the config file:

```
CU_PROVIDER, CU_BASE_URL, CU_API_KEY, CU_MODEL
```

Examples for each provider:

```jsonc
// TypeSafe Jev
{ "brain": { "provider": "typesafe", "apiKey": "ts_..." } }

// Any OpenAI-compatible endpoint
{ "brain": { "provider": "openai", "baseURL": "https://api.example.com/v1",
             "model": "some-vision-model", "apiKey": "sk-..." } }

// Whatever DSH is running right now
{ "brain": { "provider": "session" } }
```

`dsh-cu brain` prints the resolved provider, endpoint and model, and makes one
cheap test call so you find a bad key before a task fails halfway through.

### Keeping your key out of the repo

Put the key in `cu.config.json` or an environment variable, never in a file you
commit. `cu.config.json` is gitignored in this repo; `cu.config.example.json` is
the template.

## Multi-monitor

```powershell
dsh-cu ocr  --monitor 2
dsh-cu shot --monitor 2
dsh-cu fit  --window Discord --monitor 2
```

With `"monitor": 2` in the config, `run` observes only that monitor and refuses
to click coordinates that fall on another one, so a stray coordinate cannot
wander onto the wrong screen. Leave `monitor` at `0` or omit it to use every
monitor.

Windows partly off-screen are attributed to the monitor they overlap most, so a
window dragged past an edge still reports the right one.

## Background mode

```powershell
dsh-cu act click --x 500 --y 300 --mode background
```

In background mode, a click needs a control name rather than a raw coordinate,
because a bare coordinate cannot be delivered without borrowing the mouse:

```powershell
dsh-cu act click --uia "Save" --window "My App" --mode background
```

That path uses UI Automation's Invoke pattern and never touches your pointer or
the foreground window. Everything else (`ocr`, `shot`, `windows`, `read`, and
`run` observing) is already non-intrusive. For a task that must not disturb what
you are doing, keep `mode: "background"` and let the model name controls.

## Safety

These are privileged actions on a real desktop. Read this part.

- **Typing needs the foreground.** `type` and `key` bring the target window
  forward and refuse to run if they cannot. `click` on a raw coordinate does the
  same. Background clicks on named controls do not.
- **Enter sends messages.** `run` never presses Enter to submit a chat or a form
  unless the goal says to send. `--allow-send` relaxes this. Prefer goals such as
  "type X but do not send".
- **No undo.** A click or a keystroke already delivered cannot be taken back.
  Start with `--dry-run` on a new task, then run it for real.
- **Esc does not stop this tool.** It is an ordinary process, so stop it with
  Ctrl+C in its terminal, or run one action at a time.
- **Admin windows and UAC prompts cannot be operated.** That is a Windows
  security boundary, not a bug here.

## How it fits together

```
bin/dsh-cu.mjs      CLI, model loop, config
lib/win.ps1         one action per process, prints one JSON line
```

`lib/win.ps1` takes a base64-encoded JSON request and returns a single JSON
object. Every capability lives there: monitors, windows, capture, OCR, UI
Automation, input, Start menu. The Node side never talks to Windows APIs
directly, so you can call the PowerShell layer by hand when something needs
debugging.

```powershell
$req = '{"action":"monitors"}'
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($req))
powershell -NoProfile -File lib/win.ps1 -Request $b64
```

## Known limits

- **Text fields.** `read` works on classic Win32 `Edit` controls. Electron and
  custom-drawn fields do not expose text that way; use `ocr` on the window.
- **OCR quality.** The Windows engine is good on normal UI text and struggles on
  small, low-contrast or heavily styled text. Coordinates come back with the
  text, so you can still click what it found.
- **Canvas and games.** Anything that draws its own UI has no automation tree.
  Fall back to `ocr` plus coordinates, or a vision model reading `shot`.
- **Elevated windows.** Cannot be driven from a normal process.
- **One action at a time.** Two concurrent calls can fight over the pointer. Run
  one task at a time.

## Tests

```powershell
npm test
```

`test.mjs` launches Notepad, types a marker string, reads it back, and checks
screenshot, monitor filtering and window enumeration. It cleans up after itself.
Notepad must be able to open, and the desktop must be unlocked.

## License

MIT. See `LICENSE`.