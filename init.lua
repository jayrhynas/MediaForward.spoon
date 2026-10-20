--- === MediaForward ===
---
--- Forward volume and media keys from one Mac to another over HTTP.
---
--- Run in "forwarder" mode on the Mac whose keyboard you're using and
--- "receiver" mode on the Mac that plays the audio. The forwarder swallows
--- the keys and sends them to a small HTTP server inside Hammerspoon on the
--- receiver, which replays them as real keypresses, so the native HUD shows
--- and whatever app is playing responds. Hold the local modifier (⌥ by
--- default) on the forwarder to use the keys on that Mac instead.
---
--- The receiver only accepts key names from its allow-list, authenticated
--- with a shared token. Nothing it receives is ever run as code.
---
--- Forwarder:
---   hs.loadSpoon("MediaForward")
---   spoon.MediaForward:start({ mode = "forwarder", host = "jayson-m1", token = "…" })
---
--- Receiver:
---   hs.loadSpoon("MediaForward")
---   spoon.MediaForward:start({ mode = "receiver", token = "…" })

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "MediaForward"
obj.version = "0.2.0"
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

--- MediaForward.token
--- Variable
--- Shared secret, identical on both Macs. Required. Generate one with
--- `openssl rand -hex 32`.
obj.token = nil

--- MediaForward.host
--- Variable
--- Forwarder only: hostname or IP of the receiver.
obj.host = nil

--- MediaForward.port
--- Variable
--- TCP port the receiver listens on and the forwarder sends to.
obj.port = 41414

--- MediaForward.interface
--- Variable
--- Receiver only: interface name (e.g. "en0") or IP address to listen on,
--- such as the receiver's Tailscale IP. nil listens on all interfaces.
obj.interface = nil

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

---------------------------------------------------------------------------
-- Internals
---------------------------------------------------------------------------

local MARK = 0x564F4C -- tag for events this Spoon posts, so its own tap ignores them
local userData = hs.eventtap.event.properties.eventSourceUserData
local TOKEN_HEADER = "X-MediaForward-Token"

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

-- Header names aren't guaranteed to keep their case in transit.
local function header(headers, name)
  name = name:lower()
  for k, v in pairs(headers or {}) do
    if k:lower() == name then return v end
  end
end

-- Compares every byte so the time taken doesn't reveal how much matched.
local function sameToken(a, b)
  if type(a) ~= "string" or #a ~= #b then return false end
  local diff = 0
  for i = 1, #a do
    diff = diff | (a:byte(i) ~ b:byte(i))
  end
  return diff == 0
end

function obj:_forward(key)
  local url = string.format("http://%s:%d/key/%s", self.host, self.port, key)
  hs.http.asyncPost(url, "", { [TOKEN_HEADER] = self.token }, function(code, body)
    if code ~= 204 then
      self.logger.w(string.format("%s → %d %s", key, code, (body or ""):gsub("%s+$", "")))
    end
  end)
end

function obj:_handle(method, path, headers)
  local plain = { ["Content-Type"] = "text/plain" }
  if not sameToken(header(headers, TOKEN_HEADER), self.token) then
    return "bad token", 401, plain
  end
  local key = path:match("^/key/([%u_]+)$")
  if not (key and self._keys[key]) then return "unknown key", 404, plain end
  if method ~= "POST" then return "use POST", 405, plain end

  postKey(key, false) -- untagged, so the system shows its HUD
  return "", 204, {}
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
end

function obj:_startReceiver()
  self._server = hs.httpserver.new(false, false)
    :setPort(self.port)
    :setCallback(function(method, path, headers) return self:_handle(method, path, headers) end)
  if self.interface then self._server:setInterface(self.interface) end
  self._server:start()
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- MediaForward:start([config]) -> self
--- Method
--- Starts in the configured mode. `config` is an optional table of the
--- variables above, e.g. { mode = "forwarder", host = "jayson-m1", token = "…" }.
function obj:start(config)
  if config then
    for k, v in pairs(config) do self[k] = v end
  end
  if self._running then self:stop() end

  if type(self.token) ~= "string" or #self.token < 16 then
    error("MediaForward: `token` must be a string of at least 16 characters")
  end
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
--- Stops forwarding (forwarder) or stops the HTTP server (receiver).
function obj:stop()
  if self._tap then self._tap:stop(); self._tap = nil end
  if self._server then self._server:stop(); self._server = nil end
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

return obj
