--- === MediaForward ===
---
--- Forward volume and media keys from one Mac to another over the network.
---
--- Run in "forwarder" mode on the Mac whose keyboard you're using and
--- "receiver" mode on the Mac that plays the audio. The forwarder finds the
--- receiver with Bonjour, swallows the keys and sends them to a small HTTP
--- server inside Hammerspoon on the receiver, which replays them as real
--- keypresses, so the native HUD shows and whatever app is playing responds.
--- Hold the local modifier (⌥ by default) on the forwarder to use the keys on
--- that Mac instead.
---
--- The first time a forwarder connects, the receiver asks you to allow it.
--- After that the receiver only accepts key names from its allow-list, from
--- forwarders you've allowed. Nothing it receives is ever run as code.
---
--- Forwarder:
---   hs.loadSpoon("MediaForward")
---   spoon.MediaForward:start({ mode = "forwarder" })
---
--- Receiver:
---   hs.loadSpoon("MediaForward")
---   spoon.MediaForward:start({ mode = "receiver" })

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "MediaForward"
obj.version = "0.3.0"
obj.author = "Jayson"
obj.license = "MIT - https://opensource.org/licenses/MIT"

-- Info covers start-up and state changes (keys enabled, receiver found,
-- paired), so it stays quiet; each keypress logs at debug. Use
-- `spoon.MediaForward.logger.setLogLevel("debug")` to see keypresses too.
obj.logger = hs.logger.new("MediaForward", "info")

---------------------------------------------------------------------------
-- Configuration (set fields directly, or pass a table to :start())
---------------------------------------------------------------------------

--- MediaForward.mode
--- Variable
--- "forwarder" or "receiver". Required.
obj.mode = nil

--- MediaForward.receiver
--- Variable
--- Receiver: the name it advertises over Bonjour (default: the computer name).
--- Forwarder: which advertised receiver to use (default: the first one found).
obj.receiver = nil

--- MediaForward.host
--- Variable
--- Forwarder only: hostname or IP of the receiver, skipping Bonjour. Needed
--- when the Macs aren't on the same local network (e.g. only over Tailscale).
obj.host = nil

--- MediaForward.port
--- Variable
--- TCP port the receiver listens on. The forwarder uses it only with `host`;
--- with Bonjour it uses whatever port the receiver advertises.
obj.port = 41414

--- MediaForward.interface
--- Variable
--- Receiver only: interface name (e.g. "en0") or IP address to listen on.
--- nil listens on all interfaces.
obj.interface = nil

--- MediaForward.bonjour
--- Variable
--- Receiver only: advertise the receiver over Bonjour.
obj.bonjour = true

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
local SERVICE = "_mediaforward._tcp."
local TOKEN_HEADER = "X-MediaForward-Token"
local NAME_HEADER = "X-MediaForward-Name"
local TOKEN_SETTING = "MediaForward.token"   -- forwarder: its own secret
local PAIRED_SETTING = "MediaForward.paired" -- receiver: SHA-256 of token → name

local function toSet(list)
  local s = {}
  for _, k in ipairs(list) do s[k] = true end
  return s
end

local MODIFIER_SYMBOLS = { alt = "⌥", cmd = "⌘", ctrl = "⌃", shift = "⇧", fn = "fn" }

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

-- Header values travel as Latin-1, so non-ASCII names (like "Jayson’s Mac")
-- are percent-encoded on the way.
local function encodeName(s)
  return (s:gsub("[^%w%-%.%_%~ ]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function decodeName(s)
  s = (s or ""):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end):gsub("%c", "")
  if s == "" or not utf8.len(s) then return "Unknown Mac" end
  local cut = utf8.offset(s, 49) -- keep the dialog readable
  return cut and s:sub(1, cut - 1) or s
end

local function randomToken()
  local f = assert(io.open("/dev/urandom", "rb"))
  local bytes = f:read(32)
  f:close()
  return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

---------------------------------------------------------------------------
-- Forwarder
---------------------------------------------------------------------------

function obj:_post(path, callback)
  local t = self._target
  if not t then return end
  local url = string.format("http://%s:%d%s", t.host, t.port, path)
  local headers = { [TOKEN_HEADER] = self._token, [NAME_HEADER] = encodeName(hs.host.localizedName()) }
  hs.http.asyncPost(url, "", headers, function(code, body)
    if self._target == t then callback(code, body) end -- ignore replies after stop/switch
  end)
end

function obj:_forward(key)
  local name = self._target.name
  self:_post("/key/" .. key, function(code, body)
    if code == 204 then
      self.logger.d("Forwarded " .. key .. " to " .. name)
      return
    end
    self.logger.w(string.format("%s → %d %s", key, code, (body or ""):gsub("%s+$", "")))
    self._paired = false -- keys work locally until the receiver is back
    self:_checkPairing()
  end)
end

-- Asks the receiver whether this forwarder is paired, and pairs if not.
function obj:_checkPairing()
  if not self._target or self._polling or (self._retry and self._retry:running()) then return end
  self:_post("/status", function(code)
    if code == 204 then
      self._paired = true
    elseif code == 202 then
      self:_awaitApproval()
    elseif code == 401 then
      self:_requestPairing()
    elseif code == 403 then
      self:_denied()
    else
      self.logger.w(string.format("can't reach %s (%d), retrying in 10s", self._target.name, code))
      self._retry = hs.timer.doAfter(10, function() self:_checkPairing() end)
    end
  end)
end

function obj:_requestPairing()
  if self._wasDenied then return end
  self:_post("/pair", function(code)
    if code == 204 then
      self._paired = true
    elseif code == 202 then
      self:_awaitApproval()
    elseif code == 403 then
      self:_denied()
    else
      self.logger.w(string.format("pairing with %s failed (%d)", self._target.name, code))
    end
  end)
end

function obj:_awaitApproval()
  if self._polling then return end
  local name = self._target.name
  hs.alert.show("MediaForward: allow this Mac on “" .. name .. "”", 6)
  self._polling = hs.timer.doEvery(2, function()
    self:_post("/status", function(code)
      if code == 202 or not self._polling then return end -- still waiting
      self._polling:stop()
      self._polling = nil
      if code == 204 then
        self._paired = true
        hs.alert.show("Media keys → " .. name)
      elseif code == 403 then
        self:_denied()
      else
        self:_checkPairing() -- receiver restarted or is unreachable; start over
      end
    end)
  end)
end

function obj:_denied()
  self._wasDenied = true
  hs.alert.show("“" .. self._target.name .. "” denied media key forwarding")
end

function obj:_useTarget(host, port, name)
  self._target = { host = host, port = port, name = name }
  self._paired = false
  self.logger.i(string.format("using receiver %s at %s:%d", name, host, port))
  self:_checkPairing()
end

function obj:_browse()
  self._browser = hs.bonjour.new():findServices(SERVICE, "local.", function(_, what, added, service)
    if what == "error" then
      self.logger.w("Bonjour: " .. tostring(added))
      return
    end
    local name = service:name()
    if self.receiver and name ~= self.receiver then return end

    if added and not self._target then
      -- A fresh remote object, since the browser can hand back one this
      -- Hammerspoon published itself, and those refuse to resolve.
      self._resolving = hs.bonjour.service.remote(name, SERVICE, "local.")
      self._resolving:resolve(5, function(svc, result)
        if result ~= "resolved" or self._target or not self._browser then return end
        self._resolving = nil
        self:_useTarget((svc:hostname():gsub("%.$", "")), svc:port(), name)
      end)
    elseif not added and self._target and self._target.name == name then
      self.logger.i("receiver " .. name .. " went away")
      self._target = nil
      self._paired = false
    end
  end)
end

function obj:_startForwarder()
  self._token = hs.settings.get(TOKEN_SETTING)
  if not self._token then
    self._token = randomToken()
    hs.settings.set(TOKEN_SETTING, self._token)
  end

  self._tap = hs.eventtap.new({ hs.eventtap.event.types.systemDefined }, function(e)
    if e:getProperty(userData) == MARK then return false end -- our own event

    local k = e:systemKey()
    if not (k and self._keys[k.key]) then return false end

    if k.down then
      local held = self.localModifier and e:getFlags()[self.localModifier]
      if held or not (self._target and self._paired) then
        local why = held and (MODIFIER_SYMBOLS[self.localModifier] or self.localModifier) .. " held"
          or self._target and "not paired with " .. self._target.name
          or "no receiver"
        self.logger.d("Posted " .. k.key .. " locally (" .. why .. ")")
        postKey(k.key, true)
      else
        self:_forward(k.key)
      end
    end
    return true
  end):start()

  if self.host then
    self:_useTarget(self.host, self.port, self.host)
  else
    self:_browse()
  end
end

---------------------------------------------------------------------------
-- Receiver
---------------------------------------------------------------------------

function obj:_askToPair(hash, name)
  self._pending = { hash = hash }
  local f = hs.screen.mainScreen():frame()
  hs.dialog.alert(f.x + f.w / 2 - 210, f.y + f.h / 3, function(button)
    if not (self._pending and self._pending.hash == hash) then return end
    self._pending = nil
    if button == "Allow" then
      self._allowed[hash] = name
      hs.settings.set(PAIRED_SETTING, self._allowed)
      self.logger.i("paired with " .. name)
    else
      self._refused[hash] = true
    end
  end,
  "Allow “" .. name .. "” to control media keys on this Mac?",
  "A Mac on your network wants to send volume and media keys here. The name is reported by that Mac, so only allow it if you just set up MediaForward on it.",
  "Deny", "Allow", "warning")
end

function obj:_handle(method, path, headers)
  local plain = { ["Content-Type"] = "text/plain" }
  if method ~= "POST" then return "use POST", 405, plain end

  local token = header(headers, TOKEN_HEADER)
  if type(token) ~= "string" or #token < 32 then return "missing token", 401, plain end
  local hash = hs.hash.SHA256(token)
  local paired = self._allowed[hash] ~= nil
  local pending = self._pending and self._pending.hash == hash

  if path == "/status" or path == "/pair" then
    if paired then return "", 204, {} end
    if pending then return "waiting for approval", 202, plain end
    if self._refused[hash] then return "denied", 403, plain end
    if path == "/status" then return "not paired", 401, plain end
    if self._pending then return "another request is waiting", 429, plain end

    self:_askToPair(hash, decodeName(header(headers, NAME_HEADER)))
    return "waiting for approval", 202, plain
  end

  if not paired then return "not paired", 401, plain end
  local key = path:match("^/key/([%u_]+)$")
  if not (key and self._keys[key]) then return "unknown key", 404, plain end

  self.logger.d("Posted " .. key .. " from " .. self._allowed[hash])
  postKey(key, false) -- untagged, so the system shows its HUD
  return "", 204, {}
end

function obj:_startReceiver()
  self._allowed = hs.settings.get(PAIRED_SETTING) or {}
  self._refused = {}

  self._server = hs.httpserver.new(false, false)
    :setPort(self.port)
    :setCallback(function(method, path, headers) return self:_handle(method, path, headers) end)
  if self.interface then self._server:setInterface(self.interface) end
  self._server:start()

  if self.bonjour then
    self._service = hs.bonjour.service.new(self.receiver or hs.host.localizedName(), SERVICE, self.port)
      :publish(true, function(svc, result, err)
        if result == "error" then self.logger.w("Bonjour: " .. tostring(err)) end
      end)
  end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- MediaForward:start([config]) -> self
--- Method
--- Starts in the configured mode. `config` is an optional table of the
--- variables above, e.g. { mode = "forwarder", receiver = "Jayson's MacBook" }.
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
  self.logger.i("started as " .. self.mode .. (self.mode == "receiver" and (" on port " .. self.port) or ""))
  local role = self.mode == "forwarder" and "forwarding" or "receiving"
  for _, key in ipairs(self.keys) do
    self.logger.i("Enabled " .. role .. " for " .. key)
  end
  return self
end

--- MediaForward:stop() -> self
--- Method
--- Stops forwarding (forwarder) or stops the HTTP server (receiver).
function obj:stop()
  for _, field in ipairs({ "_tap", "_server", "_service", "_browser", "_resolving", "_polling", "_retry" }) do
    if self[field] then self[field]:stop(); self[field] = nil end
  end
  self._target = nil
  self._paired = false
  self._pending = nil
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
    hs.alert.show("Media keys: " .. (self.mode == "forwarder" and "forwarding" or "receiving"))
  end
  return self
end

--- MediaForward:pair() -> self
--- Method
--- Forwarder only: asks the receiver to pair again, e.g. after it was denied.
function obj:pair()
  self._wasDenied = false
  self:_checkPairing()
  return self
end

--- MediaForward:unpairAll() -> self
--- Method
--- Receiver only: forgets every forwarder you've allowed. Each one will ask
--- again the next time it connects.
function obj:unpairAll()
  self._allowed = {}
  hs.settings.clear(PAIRED_SETTING)
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
