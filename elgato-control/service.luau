--!nonstrict
local helper = (noctalia.pluginDir() or ".") .. "/bin/elgato-control"
local statusPath = noctalia.expandPath("~/.local/state/elgato-control/status.json")

local function quote(path)
  return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

local function daemonCommand()
  local hid = noctalia.getConfig("hidapi_path")
  local prefix = ""
  if type(hid) == "string" and hid ~= "" then
    prefix = "ELGATO_HIDAPI=" .. quote(hid) .. " "
  end
  return prefix .. quote(helper) .. " daemon"
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
  local raw = noctalia.readFile(statusPath)
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
  noctalia.runAsync(quote(helper) .. " init", function(_result)
    startDaemon()
    readStatus()
  end)
end

function update()
  noctalia.setUpdateInterval(2000)
  readStatus()
  noctalia.processMatches(function(matched)
    if not matched then
      startDaemon()
    end
  end, "elgato-control")
end

function onExit(_signal, _reason) end

noctalia.state.set("connected", false)
noctalia.state.set("running", false)
noctalia.setUpdateInterval(2000)
