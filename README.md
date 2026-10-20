# MediaForward.spoon

A [Hammerspoon](https://www.hammerspoon.org) Spoon that forwards volume and media keys from one Mac to another over SSH.

Built for [Universal Control](https://support.apple.com/en-us/102459) setups, where keypresses go to whichever Mac the cursor is on. If your audio plays on one Mac but your cursor is often on the other, volume and media keys end up controlling the wrong machine. MediaForward catches those keys on the Mac you're pointing at and replays them on the Mac that's playing.

- Works with any app: keys are replayed as real keypresses, so whatever is playing on the receiver responds.
- Shows the native macOS volume HUD on the receiver.
- Hold a modifier (⌥ by default) to use the keys locally instead.
- Uses a persistent SSH control socket, so keypresses feel instant.
- Reconnects automatically after sleep.

## How it works

```
 Forwarder Mac                              Receiver Mac
 ┌──────────────────────┐   ssh (shared     ┌──────────────────────────┐
 │ eventtap catches key │ ──── socket) ───▶ │ hs -c 'spoon.MediaForward│
 │ and swallows it      │                   │   :receive("PLAY")'      │
 └──────────────────────┘                   │ → posts the key locally  │
                                            └──────────────────────────┘
```

Both Macs run the same Spoon. One runs in `forwarder` mode and the other in `receiver` mode.

## Requirements

- Hammerspoon on both Macs, with **Accessibility** permission granted (System Settings → Privacy & Security → Accessibility).
- **Remote Login** enabled on the receiver (System Settings → General → Sharing).
- Key-based SSH from the forwarder to the receiver, with no password prompt. Connect once manually (`ssh <host>`) to accept the host key, because the Spoon runs ssh in batch mode and will not prompt.
- The `hs` command-line tool installed on the receiver (see below).

## Installation

On both Macs, clone this repository straight into your Spoons folder:

```sh
git clone https://github.com/jayrhynas/MediaForward.spoon.git ~/.hammerspoon/Spoons/MediaForward.spoon
```

Or download it as a ZIP from GitHub. The ZIP unpacks to a folder named `MediaForward.spoon-main`, so rename it to `MediaForward.spoon` first. Then copy it into `~/.hammerspoon/Spoons/`, or double-click it to have Hammerspoon install it. Hammerspoon only recognizes the folder by its `.spoon` extension, and `hs.loadSpoon("MediaForward")` looks for that exact name.

### Receiver

Add to `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("MediaForward")
spoon.MediaForward:start({ mode = "receiver" })
```

Reload Hammerspoon, then install the CLI from the Hammerspoon console:

```lua
hs.ipc.cliInstall()                 -- installs to /usr/local/bin
hs.ipc.cliInstall("/opt/homebrew")  -- use this on Apple Silicon if /usr/local/bin doesn't exist
```

Run `which hs` in Terminal to find the path. You'll need it for the forwarder's `hsPath` setting.

### Forwarder

Add to `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("MediaForward")
spoon.MediaForward:start({
  mode = "forwarder",
  host = "my-macbook",               -- any host or ~/.ssh/config alias
  hsPath = "/opt/homebrew/bin/hs",   -- `which hs` on the receiver
})
```

### Test it

From the forwarder's Terminal:

```sh
ssh my-macbook "/opt/homebrew/bin/hs -c 'spoon.MediaForward:receive(\"SOUND_UP\")'"
```

The receiver's volume should go up and its HUD should appear. If the command hangs, the receiver's Hammerspoon config hasn't loaded the Spoon in receiver mode.

## Configuration

Pass any of these to `:start({...})`, or set them as fields before calling `:start()`.

| Option | Mode | Default | Description |
|---|---|---|---|
| `mode` | both | — | `"forwarder"` or `"receiver"`. Required. |
| `host` | forwarder | — | SSH host of the receiver. Required. |
| `hsPath` | forwarder | `/opt/homebrew/bin/hs` | Absolute path to `hs` on the receiver. Non-interactive SSH doesn't load your shell `PATH`, so this must be absolute. |
| `keys` | both | all eight below | Keys to forward (forwarder) or accept (receiver). |
| `localModifier` | forwarder | `"alt"` | Hold this to use keys locally. One of `alt`, `cmd`, `ctrl`, `shift`, `fn`, or `nil` to disable. |
| `sshOptions` | forwarder | see below | Arguments passed to `ssh`. |
| `wakeDelay` | forwarder | `5` | Seconds to wait after wake before reconnecting. |

### Keys

The default key list is:

```lua
{ "SOUND_UP", "SOUND_DOWN", "MUTE", "PLAY", "NEXT", "PREVIOUS", "FAST", "REWIND" }
```

Some keyboards send `FAST`/`REWIND` for the ⏮/⏭ keys instead of `PREVIOUS`/`NEXT`, which is why all four are included.

On the receiver, `keys` acts as an allow-list: it only replays keys in its own list. If you add a key to the forwarder, also add it on the receiver. If you remove a key on the forwarder, it simply stops being forwarded and works normally on that Mac.

### Hotkeys

```lua
spoon.MediaForward:bindHotkeys({ toggle = { { "ctrl", "alt" }, "m" } })
```

`toggle` turns forwarding on and off and shows an alert.

## SSH notes

The default `sshOptions` open a persistent control socket:

```lua
{
  "-o", "BatchMode=yes",            -- never prompt; fail instead of hanging
  "-o", "ConnectTimeout=3",         -- give up quickly if unreachable
  "-o", "ControlMaster=auto",
  "-o", "ControlPath=~/.ssh/cm-%C",
  "-o", "ControlPersist=yes",
  "-o", "ServerAliveInterval=30",
  "-o", "ServerAliveCountMax=2",
}
```

These options are passed on the command line, so your `~/.ssh/config` doesn't need any changes. To check or close the socket:

```sh
ssh -o ControlPath=~/.ssh/cm-%C -O check my-macbook
ssh -o ControlPath=~/.ssh/cm-%C -O exit  my-macbook
```

The receiver only replays keys from its allow-list, so the SSH command can't be used to send arbitrary input.

## Troubleshooting

- **Nothing happens on the receiver.** Check the forwarder's Hammerspoon console for `ssh exited` warnings, and run the test command above.
- **The forwarder's keys stopped working locally.** That's expected: forwarded keys are swallowed. Hold the `localModifier` key, or stop the Spoon with the toggle hotkey.
- **It stops working after sleep.** The Spoon reconnects `wakeDelay` seconds after wake. If your network takes longer to come back, increase it.

## License

MIT