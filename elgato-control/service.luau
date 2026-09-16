--!nonstrict
local helper = (noctalia.pluginDir() or ".") .. "/bin/elgato-control"
local NIXOS_HIDAPI = "/run/current-system/sw/lib/libhidapi-hidraw.so.0"
local DAEMON_NEEDLE = "elgato-control daemon"

local function statusPath()
  local xdg = type(noctalia.getenv) == "function" and noctalia.getenv("XDG_STATE_HOME") or nil
  if type(xdg) == "string" and xdg ~= "" then
    return xdg .. "/elgato-control/status.json"
  end
  return noctalia.expandPath("~/.local/state/elgato-control/status.json")
end

local function quote(path)
  return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

local function hidapiPath()
  local hid = noctalia.getConfig("hidapi_path")
  if type(hid) == "string" and hid ~= "" then
    return hid
  end
  local env = type(noctalia.getenv) == "function" and noctalia.getenv("ELGATO_HIDAPI") or nil
  if type(env) == "string" and env ~= "" then
    return env
  end
  return NIXOS_HIDAPI
end

local function daemonCommand()
  -- Always export ELGATO_HIDAPI. The plugin shebang is not the flake wrapper.
  -- Needle "elgato-control daemon" must appear unquoted in /proc cmdline, so
  -- the helper is only quoted when the path is not a safe token.
  local helperToken = helper
  if not tostring(helper):match("^[%w%./_%-+]+$") then
    helperToken = quote(helper)
  end
  return "ELGATO_HIDAPI=" .. quote(hidapiPath()) .. " " .. helperToken .. " daemon"
end

local function startDaemon()
  noctalia.runStream(daemonCommand(), function(_line) end)
end

local function publish(status)
  local connected = status ~= nil and (status.classic ~= nil or status.plus ~= nil or status.pedal ~= nil)
  local product = ""
  if status and status.classic then
    product = status.classic.product or "Stream Deck"
  elseif status and status.plus then
    product = status.plus.product or "Stream Deck +"
  elseif status and status.pedal then
    product = status.pedal.product or "Pedal"
  end
  noctalia.state.set("status", status or {})
  noctalia.state.set("connected", connected)
  noctalia.state.set("product", product)
  noctalia.state.set("running", status ~= nil and status.running == true)
end

local function readStatus()
  local raw = noctalia.readFile(statusPath())
  if not raw or raw == "" then
    publish({ running = false })
    return
  end
  local parsed = noctalia.json.decode(raw)
  if type(parsed) == "table" then
    publish(parsed)
  end
end

function onEnable()
  noctalia.runAsync({ helper, "init" }, function(_result)
    startDaemon()
    readStatus()
  end)
end

function update()
  noctalia.setUpdateInterval(2000)
  readStatus()
  -- Needles are AND. Match the daemon argv, not panel status/set-key CLI.
  noctalia.processMatches(function(matched)
    if not matched then
      startDaemon()
    end
  end, DAEMON_NEEDLE)
end

function onExit(_signal, _reason) end

noctalia.state.set("connected", false)
noctalia.state.set("running", false)
noctalia.setUpdateInterval(2000)
