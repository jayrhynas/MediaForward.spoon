# MediaForward.spoon

A [Hammerspoon](https://www.hammerspoon.org) Spoon that forwards volume and media keys from one Mac to another over your local network.

Built for [Universal Control](https://support.apple.com/en-us/102459) setups, where keypresses go to whichever Mac the cursor is on. If your audio plays on one Mac but your cursor is often on the other, volume and media keys end up controlling the wrong machine. MediaForward catches those keys on the Mac you're pointing at and replays them on the Mac that's playing.

- Works with any app: keys are replayed as real keypresses, so whatever is playing on the receiver responds.
- Shows the native macOS volume HUD on the receiver.
- Finds the receiver automatically with Bonjour.
- No passwords or tokens to copy: you approve the forwarder once, on the receiver.
- Hold a modifier (⌥ by default) to use the keys locally instead.
- The receiver accepts key names only, never commands.

## How it works

```
 Forwarder Mac                              Receiver Mac
 ┌──────────────────────┐  POST /key/PLAY   ┌──────────────────────────┐
 │ eventtap catches key │ ── + token ─────▶ │ hs.httpserver checks the │
 │ and swallows it      │                   │ token and the allow-list │
 └──────────────────────┘                   │ → posts the key locally  │
            ▲                               └──────────────────────────┘
            └──── Bonjour: _mediaforward._tcp ───────────┘
```

Both Macs run the same Spoon. One runs in `forwarder` mode and the other in `receiver` mode. The receiver runs a small HTTP server inside Hammerspoon and advertises it over Bonjour. The forwarder finds it, and on first contact asks to pair. The receiver shows a dialog:

> Allow "Jayson's Mac mini" to control media keys on this Mac?

Click **Allow** and the forwarder's keys go to the receiver from then on. Until a forwarder is paired, and whenever the receiver can't be reached, its keys keep working locally.

## Requirements

- Hammerspoon on both Macs, with **Accessibility** permission granted (System Settings → Privacy & Security → Accessibility).
- Both Macs on the same local network, for Bonjour. (Otherwise, see [Without Bonjour](#without-bonjour).)
- If the macOS firewall is on, allow incoming connections for Hammerspoon on the receiver when prompted.

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

### Forwarder

Add to `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("MediaForward")
spoon.MediaForward:start({ mode = "forwarder" })
```

Reload Hammerspoon on both Macs. The forwarder shows *"MediaForward: allow this Mac on …"*, and the receiver shows the pairing dialog. Click **Allow**. The forwarder confirms with *"Media keys → …"*.

If more than one receiver is on your network, pick one by the name it advertises (its computer name by default):

```lua
spoon.MediaForward:start({ mode = "forwarder", receiver = "Jayson's MacBook Pro" })
```

## Configuration

Pass any of these to `:start({...})`, or set them as fields before calling `:start()`.

| Option | Mode | Default | Description |
|---|---|---|---|
| `mode` | both | — | `"forwarder"` or `"receiver"`. Required. |
| `receiver` | both | computer name / first found | Receiver: the name it advertises. Forwarder: which receiver to use. |
| `host` | forwarder | `nil` | Hostname or IP of the receiver. Skips Bonjour. |
| `port` | both | `41414` | Port the receiver listens on. The forwarder only uses it with `host`. |
| `interface` | receiver | `nil` (all) | Interface name (e.g. `"en0"`) or IP address to listen on. |
| `bonjour` | receiver | `true` | Advertise the receiver over Bonjour. |
| `keys` | both | all eight below | Keys to forward (forwarder) or accept (receiver). |
| `localModifier` | forwarder | `"alt"` | Hold this to use keys locally. One of `alt`, `cmd`, `ctrl`, `shift`, `fn`, or `nil` to disable. |

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

`toggle` turns forwarding on and off (forwarder) or starts and stops the server (receiver), and shows an alert.

### Without Bonjour

Bonjour only works on the local network. If the Macs reach each other some other way, such as only over [Tailscale](https://tailscale.com), give the forwarder the receiver's address:

```lua
spoon.MediaForward:start({ mode = "forwarder", host = "jayson-m1" })  -- e.g. a Tailscale name
```

Pairing works the same way.

## Pairing

- **Pairing again after a denial.** If you clicked Deny by mistake, run `spoon.MediaForward:pair()` in the forwarder's console. A denial is remembered until the receiver's Hammerspoon reloads.
- **Unpairing everything.** `spoon.MediaForward:unpairAll()` on the receiver forgets every forwarder. Each one asks again the next time it connects.
- **Where pairing is stored.** Each forwarder generates a random 256-bit token on first run and keeps it in `hs.settings` (`MediaForward.token`). The receiver stores only a SHA-256 hash of each allowed token, with the forwarder's name (`MediaForward.paired`).

## Security

The receiver never evaluates anything it receives. A request names a key, the key is looked up in the allow-list, and the only possible effect is a press of one of those media keys. Requests from forwarders you haven't allowed are rejected before the key is even looked at.

Things to know:

- **The name in the pairing dialog is reported by the other Mac**, so it can't be trusted on its own. Only click Allow right after you've set up a forwarder yourself. Only one pairing request can be pending at a time, and once denied, a token can't ask again until the receiver reloads.
- **The connection is plain HTTP.** Someone watching traffic on your network could copy a forwarder's token and replay media keys (nothing more). On networks you don't trust, use Tailscale with `host`, and set the receiver's `interface` to its Tailscale IP so it isn't reachable from the local network at all. That turns off Bonjour discovery, since Bonjour can't reach that interface.

## Troubleshooting

- **The forwarder's keys still work locally.** It hasn't found or paired with a receiver yet. Check its Hammerspoon console for `using receiver …`. If that never appears, Bonjour can't see the receiver: check that both Macs are on the same network, or use `host`.
- **The pairing dialog never appears.** Check the receiver's console for `started as receiver` and the firewall setting. You can see whether it's advertised with `dns-sd -B _mediaforward._tcp`.
- **The forwarder's keys stopped working locally.** That's expected once it's paired: forwarded keys are swallowed. Hold the `localModifier` key, or stop the Spoon with the toggle hotkey.
- **The receiver doesn't start.** Another app may be using the port. Pick a different `port` (and update `host`-based forwarders to match).

## License

MIT
