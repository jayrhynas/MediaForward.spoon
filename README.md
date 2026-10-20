# MediaForward.spoon

A [Hammerspoon](https://www.hammerspoon.org) Spoon that forwards volume and media keys from one Mac to another over your local network.

Built for [Universal Control](https://support.apple.com/en-us/102459) setups, where keypresses go to whichever Mac the cursor is on. If your audio plays on one Mac but your cursor is often on the other, volume and media keys end up controlling the wrong machine. MediaForward catches those keys on the Mac you're pointing at and replays them on the Mac that's playing.

- Works with any app: keys are replayed as real keypresses, so whatever is playing on the receiver responds.
- Shows the native macOS volume HUD on the receiver.
- Hold a modifier (⌥ by default) to use the keys locally instead.
- No SSH, no Remote Login, no `hs` CLI: the receiver accepts key names only, never commands.

## How it works

```
 Forwarder Mac                              Receiver Mac
 ┌──────────────────────┐  POST /key/PLAY   ┌──────────────────────────┐
 │ eventtap catches key │ ── + token ─────▶ │ hs.httpserver checks the │
 │ and swallows it      │                   │ token and the allow-list │
 └──────────────────────┘                   │ → posts the key locally  │
                                            └──────────────────────────┘
```

Both Macs run the same Spoon. One runs in `forwarder` mode and the other in `receiver` mode. The receiver runs a small HTTP server inside Hammerspoon that understands exactly one request: `POST /key/<NAME>` with the shared token. Anything else is rejected.

## Requirements

- Hammerspoon on both Macs, with **Accessibility** permission granted (System Settings → Privacy & Security → Accessibility).
- The forwarder must be able to reach the receiver on the chosen port (`41414` by default). If the macOS firewall is on, allow incoming connections for Hammerspoon on the receiver when prompted.

## Installation

On both Macs, clone this repository straight into your Spoons folder:

```sh
git clone https://github.com/jayrhynas/MediaForward.spoon.git ~/.hammerspoon/Spoons/MediaForward.spoon
```

Or download it as a ZIP from GitHub. The ZIP unpacks to a folder named `MediaForward.spoon-main`, so rename it to `MediaForward.spoon` first. Then copy it into `~/.hammerspoon/Spoons/`, or double-click it to have Hammerspoon install it. Hammerspoon only recognizes the folder by its `.spoon` extension, and `hs.loadSpoon("MediaForward")` looks for that exact name.

### Token

Both Macs share a secret token. Generate one:

```sh
openssl rand -hex 32
```

To keep it out of your `init.lua` (and any dotfiles repo), store it once on each Mac from the Hammerspoon console:

```lua
hs.settings.set("MediaForward.token", "paste-the-token-here")
```

### Receiver

Add to `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("MediaForward")
spoon.MediaForward:start({
  mode = "receiver",
  token = hs.settings.get("MediaForward.token"),
})
```

### Forwarder

Add to `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("MediaForward")
spoon.MediaForward:start({
  mode = "forwarder",
  host = "my-macbook.local",         -- hostname or IP of the receiver
  token = hs.settings.get("MediaForward.token"),
})
```

### Test it

From the forwarder's Terminal:

```sh
curl -i -X POST -d '' -H "X-MediaForward-Token: $TOKEN" http://my-macbook.local:41414/key/SOUND_UP
```

The receiver's volume should go up, its HUD should appear, and curl should print `204 No Content`. Other responses:

| Status | Meaning |
|---|---|
| `401` | The token is missing or doesn't match the receiver's. |
| `404` | The key isn't in the receiver's `keys` allow-list. |
| `405` | The request wasn't a `POST`. |
| `400` | A `POST` with no body; send `-d ''`. |
| no response | The receiver isn't running, the host or port is wrong, or a firewall is blocking it. |

## Configuration

Pass any of these to `:start({...})`, or set them as fields before calling `:start()`.

| Option | Mode | Default | Description |
|---|---|---|---|
| `mode` | both | — | `"forwarder"` or `"receiver"`. Required. |
| `token` | both | — | Shared secret, identical on both Macs, at least 16 characters. Required. |
| `host` | forwarder | — | Hostname or IP of the receiver. Required. |
| `port` | both | `41414` | Port the receiver listens on and the forwarder sends to. |
| `interface` | receiver | `nil` (all) | Interface name (e.g. `"en0"`) or IP address to listen on. |
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

## Security

The receiver never evaluates anything it receives. A request names a key, the key is looked up in the allow-list, and the only possible effect is a press of one of those media keys. A request with a bad token is rejected before the key is even looked at. The token comparison takes the same time whether or not any part of the token matches.

The connection is plain HTTP, so on a shared network someone watching traffic could read the token and replay volume and media keys (nothing more). To close that off:

- Use [Tailscale](https://tailscale.com) or another VPN, which encrypts the traffic, and point `host` at the receiver's Tailscale name.
- Set `interface` on the receiver to its Tailscale IP, so the server isn't reachable from the local network at all.

## Troubleshooting

- **Nothing happens on the receiver.** Check the forwarder's Hammerspoon console for warnings like `SOUND_UP → 401 bad token`, and run the test command above.
- **The forwarder's keys stopped working locally.** That's expected: forwarded keys are swallowed. Hold the `localModifier` key, or stop the Spoon with the toggle hotkey.
- **The receiver doesn't start.** Another app may be using the port. Pick a different `port` on both Macs.

## License

MIT
