--- === MediaForward ===
---
--- Forward volume and media keys from one Mac to another over SSH.
---
--- Run in "forwarder" mode on the Mac whose keyboard you're using and
--- "receiver" mode on the Mac that plays the audio. The forwarder swallows
--- the keys and asks the receiver (via the `hs` CLI over SSH) to replay them
--- as real keypresses, so the native HUD shows and whatever app is playing
--- responds. Hold the local modifier (⌥ by default) on the forwarder to use
--- the keys on that Mac instead.
---
--- Forwarder:
---   hs.loadSpoon("MediaForward")
---   spoon.MediaForward:start({ mode = "forwarder", host = "jayson-m1" })
---
--- Receiver (needs the hs CLI installed: hs.ipc.cliInstall()):
---   hs.loadSpoon("MediaForward")
---   spoon.MediaForward:start({ mode = "receiver" })

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "MediaForward"
obj.version = "0.1.0"
obj.author = "Jayson"
obj.license = "MIT - https://opensource.org/licenses/MIT"

obj.logger = hs.logger.new("MediaForward")

---------------------------------------------------------------------------
-- Configuration (set fields directly, or pass a table to :start())
---------------------------------------------------------------------------

--- MediaForward.mode
--- Variable
--- "forwarder" or "receiver". Required.
obj.mode = nil

--- MediaForward.host
--- Variable
--- Forwarder only: SSH host of the receiver (an alias from ~/.ssh/config works).
obj.host = nil

--- MediaForward.hsPath
--- Variable
--- Forwarder only: path to the `hs` CLI on the receiver. Non-interactive SSH
--- doesn't load your shell PATH, so this must be absolute.
obj.hsPath = "/opt/homebrew/bin/hs"

--- MediaForward.localModifier
--- Variable
--- Forwarder only: hold this modifier to use the keys locally instead of
--- forwarding. One of "alt", "cmd", "ctrl", "shift", "fn", or nil to disable.
obj.localModifier = "alt"

--- MediaForward.keys
--- Variable
--- System keys to forward (forwarder) or accept (receiver).
obj.keys = {
  "SOUND_UP", "SOUND_DOWN", "MUTE",
  "PLAY", "NEXT", "PREVIOUS", "FAST", "REWIND",
}

--- MediaForward.sshOptions
--- Variable
--- Forwarder only: extra ssh arguments. The defaults keep a persistent control
--- socket open so keypresses don't pay the connection cost.
obj.sshOptions = {
  "-o", "BatchMode=yes",            -- never prompt; fail instead of hanging
  "-o", "ConnectTimeout=3",         -- give up quickly if unreachable
  "-o", "ControlMaster=auto",       -- create or reuse a shared connection
  "-o", "ControlPath=~/.ssh/cm-%C", -- socket path (hash of host/user/port)
  "-o", "ControlPersist=yes",       -- keep the connection open indefinitely
  "-o", "ServerAliveInterval=30",   -- detect dead connections
  "-o", "ServerAliveCountMax=2",
}

--- MediaForward.wakeDelay
--- Variable
--- Forwarder only: seconds after wake before re-opening the SSH connection.
obj.wakeDelay = 5

---------------------------------------------------------------------------
-- Internals
---------------------------------------------------------------------------

local MARK = 0x564F4C -- tag for events this Spoon posts, so its own tap ignores them
local userData = hs.eventtap.event.properties.eventSourceUserData

local function toSet(list)
  local s = {}
  for _, k in ipairs(list) do s[k] = true end
  return s
end

local function postKey(key, tagged)
  for _, down in ipairs({ true, false }) do
    local ev = hs.eventtap.event.newSystemKeyEvent(key, down)
    if tagged then ev:setProperty(userData, MARK) end
    ev:post()
  end
end

function obj:_ssh(remoteCmd)
  local args = hs.fnutils.concat(hs.fnutils.copy(self.sshOptions), { self.host, remoteCmd })
  local task = hs.task.new("/usr/bin/ssh", function(code, _, stderr)
    if code ~= 0 then
      self.logger.w(string.format("ssh exited %d: %s", code, (stderr or ""):gsub("%s+$", "")))
    end
  end, args)
  if task then task:start() end
end

function obj:_warm()
  self:_ssh("true")
end

function obj:_forward(key)
  self:_ssh(string.format("%s -c 'spoon.%s:receive(\"%s\")'", self.hsPath, self.name, key))
end

function obj:_startForwarder()
  if not self.host then error("MediaForward: `host` is required in forwarder mode") end

  self._tap = hs.eventtap.new({ hs.eventtap.event.types.systemDefined }, function(e)
    if e:getProperty(userData) == MARK then return false end -- our own event

    local k = e:systemKey()
    if not (k and self._keys[k.key]) then return false end

    if k.down then
      if self.localModifier and e:getFlags()[self.localModifier] then
        postKey(k.key, true)
      else
        self:_forward(k.key)
      end
    end
    return true
  end):start()

  self._wake = hs.caffeinate.watcher.new(function(ev)
    if ev == hs.caffeinate.watcher.systemDidWake then
      hs.timer.doAfter(self.wakeDelay, function() self:_warm() end)
    end
  end):start()

  self:_warm()
end

function obj:_startReceiver()
  require("hs.ipc") -- lets the hs CLI reach this instance
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- MediaForward:start([config]) -> self
--- Method
--- Starts in the configured mode. `config` is an optional table of the
--- variables above, e.g. { mode = "forwarder", host = "jayson-m1" }.
function obj:start(config)
  if config then
    for k, v in pairs(config) do self[k] = v end
  end
  if self._running then self:stop() end

  self._keys = toSet(self.keys)

  if self.mode == "forwarder" then
    self:_startForwarder()
  elseif self.mode == "receiver" then
    self:_startReceiver()
  else
    error('MediaForward: `mode` must be "forwarder" or "receiver"')
  end

  self._running = true
  self.logger.i("started as " .. self.mode .. (self.host and (" → " .. self.host) or ""))
  return self
end

--- MediaForward:stop() -> self
--- Method
--- Stops forwarding (forwarder) or ignores incoming keys (receiver).
function obj:stop()
  if self._tap then self._tap:stop(); self._tap = nil end
  if self._wake then self._wake:stop(); self._wake = nil end
  self._running = false
  return self
end

--- MediaForward:toggle() -> self
--- Method
--- Toggles between running and stopped, with an on-screen alert.
function obj:toggle()
  if self._running then
    self:stop()
    hs.alert.show("Media keys: local")
  else
    self:start()
    hs.alert.show("Media keys: " .. (self.mode == "forwarder" and ("→ " .. self.host) or "receiving"))
  end
  return self
end

--- MediaForward:bindHotkeys(mapping) -> self
--- Method
--- Binds hotkeys. Supported key: `toggle`.
---   spoon.MediaForward:bindHotkeys({ toggle = { { "ctrl", "alt" }, "m" } })
function obj:bindHotkeys(mapping)
  hs.spoons.bindHotkeysToSpec({ toggle = hs.fnutils.partial(self.toggle, self) }, mapping)
  return self
end

--- MediaForward:receive(key)
--- Method
--- Receiver only: called over SSH by the forwarder. Replays `key` locally if
--- it's in `keys` and the Spoon is running.
function obj:receive(key)
  if not (self._running and self.mode == "receiver") then return end
  if self._keys[key] then postKey(key, false) end
end

return obj
