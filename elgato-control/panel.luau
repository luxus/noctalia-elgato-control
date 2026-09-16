--!nonstrict
-- Omarchy-style visual key/dial/pedal editor on Noctalia v5 (plugin_api 24).
-- Layout follows official-plugins/example/panel.luau: column/row/scroll only.
-- The box node is a leaf color swatch, not a flex parent — using it as a layout
-- parent produced a black panel on lea.
-- Do not error() at load: a thrown panel entry is an empty surface.

local editor
local requireOk, requireResult = pcall(require, "./editor.luau")
if requireOk and type(requireResult) == "table" then
  editor = requireResult
else
  editor = nil
  if type(noctalia) == "table" and type(noctalia.log) == "function" then
    noctalia.log("Elgato Control: require(./editor.luau) failed: " .. tostring(requireResult))
  end
end

local helper = (type(noctalia) == "table" and type(noctalia.pluginDir) == "function" and noctalia.pluginDir() or ".") .. "/bin/elgato-control"
local open = false
local status = { running = false, plus = nil, classic = nil, pedal = nil, wave = nil, lights = {}, profile = "Noctalia Default" }
local profile = { keys = {}, classicKeys = {}, dials = {}, pedals = {} }
local catalog = {}
local selectedDevice = "classic"
local selectedControl = "key"
local selectedIndex = 1
local selectedSlot = "press"
local selectedLight = 0
local filter = ""
local errorText = ""
local catalogLoading = false
local mutating = false
local lightBrightness = 40
local lightKelvin = 5000
local tree

local function decodeJson(raw)
  if type(raw) ~= "string" or raw == "" then
    return nil
  end
  if type(noctalia) ~= "table" or type(noctalia.json) ~= "table" or type(noctalia.json.decode) ~= "function" then
    return nil
  end
  local parsed = noctalia.json.decode(raw)
  if type(parsed) == "table" then
    return parsed
  end
  return nil
end

local function jsonPath(kind)
  if kind == "status" then
    local xdg = type(noctalia.getenv) == "function" and noctalia.getenv("XDG_STATE_HOME") or nil
    if type(xdg) == "string" and xdg ~= "" then
      return xdg .. "/elgato-control/status.json"
    end
    return noctalia.expandPath("~/.local/state/elgato-control/status.json")
  end
  local xdg = type(noctalia.getenv) == "function" and noctalia.getenv("XDG_CONFIG_HOME") or nil
  if type(xdg) == "string" and xdg ~= "" then
    return xdg .. "/elgato-control/profile.json"
  end
  return noctalia.expandPath("~/.config/elgato-control/profile.json")
end

local function readJsonFile(kind)
  if type(noctalia.readFile) ~= "function" then
    return nil
  end
  local raw = noctalia.readFile(jsonPath(kind))
  return decodeJson(raw)
end

local function helperArgv(parts)
  local argv = {}
  if type(noctalia.commandExists) == "function" and noctalia.commandExists("python3") then
    table.insert(argv, "python3")
  end
  table.insert(argv, helper)
  for _, part in ipairs(parts) do
    table.insert(argv, part)
  end
  return argv
end

local function fallbackEditor()
  return {
    capabilities = function(value)
      value = value or {}
      return {
        plus = type(value.plus) == "table" or value.plus == true,
        classic = type(value.classic) == "table" or value.classic == true,
        pedal = type(value.pedal) == "table" or value.pedal == true,
        wave = type(value.wave) == "table" or value.wave == true,
        keylight = false,
        connected = value.plus ~= nil or value.classic ~= nil or value.pedal ~= nil or value.wave ~= nil,
      }
    end,
    deviceTabs = function(caps)
      local tabs = {}
      if caps and caps.classic then
        table.insert(tabs, "classic")
      end
      if caps and caps.plus then
        table.insert(tabs, "plus")
      end
      if caps and caps.pedal then
        table.insert(tabs, "pedal")
      end
      if caps and caps.wave then
        table.insert(tabs, "wave")
      end
      if caps and caps.keylight then
        table.insert(tabs, "lights")
      end
      if #tabs == 0 then
        return { "classic", "plus" }
      end
      return tabs
    end,
    tabLabel = function(id)
      return id
    end,
    pickDevice = function(tabs, current)
      return current or (tabs and tabs[1]) or "classic"
    end,
    keysFor = function(value, device)
      value = value or {}
      if device == "classic" then
        return value.classicKeys or {}
      end
      if device == "plus" then
        return value.keys or {}
      end
      if device == "pedal" then
        return value.pedals or {}
      end
      if device == "plus-dials" then
        return value.dials or {}
      end
      return {}
    end,
    padKeys = function(keys, count, fallback)
      local out = {}
      for i = 1, count do
        out[i] = (keys and keys[i]) or { action = fallback or "none" }
      end
      return out
    end,
    currentAction = function(keys, index)
      local item = keys and keys[index]
      return (type(item) == "table" and item.action) or "none"
    end,
    dialSlot = function()
      return "none"
    end,
    saveArgv = function(path, device, control, index, action, slot)
      if control == "dial" then
        return { path, "set-dial", tostring(index), slot or "press", action }
      end
      if control == "pedal" then
        return { path, "set-pedal", tostring(index), action }
      end
      return { path, "set-key", "--device", device == "classic" and "classic" or "plus", tostring(index), action }
    end,
    waveArgv = function(path, action)
      return { path, "wave", action }
    end,
    lightsArgv = function(path, action, target, value)
      local argv = { path, "lights", action, "--target", target or "all" }
      if value ~= nil then
        table.insert(argv, "--value")
        table.insert(argv, tostring(math.floor(value)))
      end
      return argv
    end,
    filterCatalog = function(items)
      return items or {}
    end,
    normalizeCatalog = function(items)
      return items or {}
    end,
    inspectorTitle = function(device, control, index)
      return tostring(device) .. " " .. tostring(control) .. " " .. tostring(index)
    end,
    shortLabel = function(item)
      if type(item) == "table" then
        return item.label or item.action or "none"
      end
      return tostring(item or "none")
    end,
    kelvin = function(mireds, fallback)
      local value = tonumber(mireds)
      if not value or value <= 0 then
        return fallback or 5000
      end
      return math.floor((1000000 / value) + 0.5)
    end,
  }
end

if editor == nil then
  editor = fallbackEditor()
  errorText = "editor.luau did not load; showing a fallback grid"
end

local function paint()
  if not open then
    return
  end
  if type(panel) ~= "table" or type(panel.render) ~= "function" then
    if type(noctalia) == "table" and type(noctalia.log) == "function" then
      noctalia.log("Elgato Control: panel.render is missing")
    end
    return
  end
  if type(tree) ~= "function" then
    if type(ui) == "table" and type(ui.column) == "function" and type(ui.label) == "function" then
      panel.render(ui.column({ flexGrow = 1, padding = 16, gap = 8 }, {
        ui.label({ text = "Elgato Control", fontWeight = "bold" }),
        ui.label({ text = "Panel tree is not ready.", color = "error" }),
      }))
    end
    return
  end
  panel.render(tree())
end

local function commandArgv(argv)
  local parts = {}
  local start = 1
  if argv[1] == "python3" then
    start = argv[2] == helper and 3 or 2
  elseif argv[1] == helper then
    start = 2
  end
  for i = start, #argv do
    table.insert(parts, argv[i])
  end
  return helperArgv(parts)
end

local function runHelper(argv, after, timeoutMs)
  if type(noctalia.runAsync) ~= "function" then
    errorText = "noctalia.runAsync is missing"
    paint()
    return
  end
  local command = commandArgv(argv)
  local launched = noctalia.runAsync(command, function(result)
    mutating = false
    result = result or {}
    if result.timedOut then
      errorText = "elgato-control timed out"
      noctalia.log(errorText)
    elseif result.exitCode ~= 0 then
      local err = (result.stderr ~= "" and result.stderr) or result.stdout
      errorText = (err ~= "" and err or "elgato-control failed")
      noctalia.log("elgato-control failed: " .. errorText)
    else
      errorText = ""
    end
    if after then
      after(result)
    end
    paint()
  end, timeoutMs)
  if launched == false then
    mutating = false
    errorText = "Could not start elgato-control"
    noctalia.log(errorText)
    paint()
  end
end

local function caps()
  return editor.capabilities(status)
end

local function tabs()
  return editor.deviceTabs(caps())
end

local function loadFromDisk()
  local parsedStatus = readJsonFile("status")
  if parsedStatus then
    status = parsedStatus
    selectedDevice = editor.pickDevice(tabs(), selectedDevice)
  end
  local parsedProfile = readJsonFile("profile")
  if parsedProfile then
    profile = parsedProfile
  end
end

local function loadCatalog()
  if #catalog > 0 or catalogLoading then
    return
  end
  catalogLoading = true
  runHelper({ helper, "catalog" }, function(result)
    catalogLoading = false
    if result.exitCode == 0 and result.stdout ~= "" then
      local parsed = decodeJson(result.stdout)
      if type(parsed) == "table" then
        catalog = editor.normalizeCatalog(parsed)
      end
    end
  end, 20000)
end

local function refresh()
  if not open then
    return
  end
  loadFromDisk()
  loadCatalog()
  paint()
end

local function currentMappedAction()
  if selectedDevice == "pedal" then
    return editor.currentAction(editor.padKeys(editor.keysFor(profile, "pedal"), 3, "none"), selectedIndex)
  end
  if selectedControl == "dial" then
    return editor.dialSlot(editor.keysFor(profile, "plus-dials"), selectedIndex, selectedSlot)
  end
  if selectedDevice == "classic" then
    return editor.currentAction(editor.padKeys(editor.keysFor(profile, "classic"), 15, "none"), selectedIndex)
  end
  if selectedDevice == "plus" then
    return editor.currentAction(editor.padKeys(editor.keysFor(profile, "plus"), 8, "none"), selectedIndex)
  end
  return "none"
end

local function saveAction(action, slot)
  if mutating then
    return
  end
  mutating = true
  local argv = editor.saveArgv(helper, selectedDevice, selectedControl, selectedIndex, action, slot or selectedSlot)
  runHelper(argv, function(result)
    if result.exitCode == 0 then
      loadFromDisk()
    end
  end)
end

local function selectKey(index)
  selectedControl = "key"
  selectedIndex = index
  paint()
end

local function selectDial(index)
  selectedControl = "dial"
  selectedIndex = index
  selectedSlot = "press"
  paint()
end

local function selectPedal(index)
  selectedDevice = "pedal"
  selectedControl = "pedal"
  selectedIndex = index
  paint()
end

local function keyTile(index, key, cols)
  local selected = selectedControl == "key" and selectedIndex == index
  local action = (key or {}).action or "none"
  return ui.column({
    key = "key-" .. tostring(index),
    gap = 2,
    padding = 6,
    align = "center",
    justify = "center",
    fill = selected and "surface_variant" or "surface",
    border = selected and "primary" or "outline",
    borderWidth = selected and 2 or 1,
    radius = 8,
    flexGrow = 1,
    minHeight = cols == 5 and 56 or 72,
    onClick = function()
      selectKey(index)
    end,
  }, {
    ui.label({ text = tostring(index), fontSize = 9, color = "on_surface_variant" }),
    ui.label({
      text = editor.shortLabel({ action = action, label = (key or {}).label }),
      fontSize = 10,
      color = "on_surface",
      maxLines = 2,
      textAlign = "center",
    }),
  })
end

local function keyGrid(keys, cols)
  local rows = {}
  local row = {}
  for index, key in ipairs(keys) do
    table.insert(row, keyTile(index, key, cols))
    if #row == cols then
      table.insert(rows, ui.row({ gap = 8, align = "stretch" }, row))
      row = {}
    end
  end
  if #row > 0 then
    table.insert(rows, ui.row({ gap = 8, align = "stretch" }, row))
  end
  return ui.column({ gap = 8, align = "stretch" }, rows)
end

local function dialRow()
  local children = {}
  for index, dial in ipairs(editor.padKeys(editor.keysFor(profile, "plus-dials"), 4, "none")) do
    local selected = selectedControl == "dial" and selectedIndex == index
    table.insert(children, ui.column({
      key = "dial-" .. tostring(index),
      gap = 4,
      padding = 4,
      align = "center",
      flexGrow = 1,
      fill = selected and "surface_variant" or "surface",
      border = selected and "primary" or "outline",
      borderWidth = selected and 2 or 1,
      radius = 8,
      onClick = function()
        selectDial(index)
      end,
    }, {
      ui.label({ text = dial.label or ("Dial " .. index), fontSize = 9, color = "on_surface_variant", maxLines = 1 }),
      ui.label({ text = tostring(index), fontSize = 14, fontWeight = "bold" }),
    }))
  end
  return ui.row({ gap = 8, align = "stretch" }, children)
end

local function deviceButtons()
  local buttons = {}
  for _, id in ipairs(tabs()) do
    table.insert(buttons, ui.button({
      key = "tab-" .. id,
      text = editor.tabLabel(id, id == "wave" and (status.wave or {}).product or nil),
      variant = selectedDevice == id and "primary" or "outline",
      controlSize = "sm",
      onClick = function()
        selectedDevice = id
        selectedIndex = 1
        selectedSlot = "press"
        selectedLight = 0
        if id == "plus" or id == "classic" then
          selectedControl = "key"
        elseif id == "pedal" then
          selectedControl = "pedal"
        else
          selectedControl = id
        end
        paint()
      end,
    }))
  end
  return ui.row({ gap = 8, align = "center" }, buttons)
end

local function classicPreview()
  local keys = editor.padKeys(editor.keysFor(profile, "classic"), 15, "none")
  return ui.column({ gap = 10, padding = 12, fill = "surface", radius = 12, border = "outline", borderWidth = 1, align = "stretch" }, {
    ui.label({ text = "STREAM DECK · 5×3", fontSize = 10, fontWeight = "medium", color = "on_surface_variant" }),
    keyGrid(keys, 5),
  })
end

local function plusPreview()
  local keys = editor.padKeys(editor.keysFor(profile, "plus"), 8, "none")
  return ui.column({ gap = 10, padding = 12, fill = "surface", radius = 12, border = "outline", borderWidth = 1, align = "stretch" }, {
    ui.label({ text = "STREAM DECK + · 4×2", fontSize = 10, fontWeight = "medium", color = "on_surface_variant" }),
    keyGrid(keys, 4),
    ui.row({
      padding = 8,
      minHeight = 44,
      fill = "surface_variant",
      radius = 8,
      border = "outline",
      borderWidth = 1,
      justify = "space_between",
      align = "center",
    }, {
      ui.label({ text = "LCD STRIP", fontSize = 9, color = "on_surface_variant" }),
      ui.label({ text = tostring(status.brightness or profile.brightness or 55) .. "% backlight", fontSize = 9, color = "on_surface_variant" }),
    }),
    dialRow(),
  })
end

local function pedalPreview()
  local names = { "LEFT", "MIDDLE", "RIGHT" }
  local children = {}
  local pedals = editor.padKeys(editor.keysFor(profile, "pedal"), 3, "none")
  for index, pedal in ipairs(pedals) do
    local selected = selectedIndex == index and selectedControl == "pedal"
    table.insert(children, ui.column({
      key = "pedal-" .. tostring(index),
      gap = 8,
      padding = 12,
      align = "center",
      justify = "center",
      flexGrow = 1,
      minHeight = 120,
      fill = selected and "surface_variant" or "surface",
      border = selected and "primary" or "outline",
      borderWidth = selected and 2 or 1,
      radius = 8,
      onClick = function()
        selectPedal(index)
      end,
    }, {
      ui.label({ text = names[index], fontSize = 9, fontWeight = "medium", color = "on_surface_variant" }),
      ui.label({ text = editor.shortLabel(pedal), fontSize = 11, maxLines = 2, textAlign = "center" }),
    }))
  end
  return ui.row({ gap = 10, padding = 12, fill = "surface", radius = 12, border = "outline", borderWidth = 1, align = "stretch" }, children)
end

local function wavePreview()
  local wave = status.wave or {}
  local muted = wave.muted == true
  return ui.column({ gap = 8, padding = 16, fill = "surface", radius = 12, border = "outline", borderWidth = 1, align = "center" }, {
    ui.glyph({ name = "microphone", size = 36, color = muted and "error" or "primary" }),
    ui.label({ text = wave.product or "Wave microphone", fontWeight = "bold" }),
    ui.label({ text = muted and "MUTED" or "LIVE", color = muted and "error" or "primary", fontSize = 11 }),
    ui.progress({ progress = math.max(0, math.min(1, (wave.gainPercent or 0) / 100)), height = 8 }),
    ui.label({
      text = "Gain " .. tostring(wave.gainDb or "--") .. " dB · HP " .. tostring(wave.headphonePercent or "--") .. "%",
      fontSize = 11,
      color = "on_surface_variant",
    }),
  })
end

local function lightTile(index, title, subtitle, selected, on)
  return ui.column({
    key = "light-" .. tostring(index),
    gap = 6,
    padding = 10,
    align = "center",
    justify = "center",
    flexGrow = 1,
    minHeight = 110,
    fill = selected and "surface_variant" or "surface",
    border = selected and "primary" or "outline",
    borderWidth = selected and 2 or 1,
    radius = 8,
    onClick = function()
      selectedLight = index
      paint()
    end,
  }, {
    ui.glyph({ name = "bulb", size = 22, color = on and "primary" or "on_surface_variant" }),
    ui.label({ text = title, fontSize = 10, fontWeight = "bold", maxLines = 1, textAlign = "center" }),
    ui.label({ text = subtitle, fontSize = 9, color = "on_surface_variant", maxLines = 1 }),
  })
end

local function lightsPreview()
  local lights = status.lights or {}
  local tiles = {
    lightTile(0, "ALL LIGHTS", "Grouped", selectedLight == 0, true),
  }
  for index, light in ipairs(lights) do
    local subtitle = "off-line"
    if light.reachable then
      subtitle = tostring(light.brightness or 0) .. "% · " .. tostring(editor.kelvin(light.temperature, 5000)) .. "K"
    end
    table.insert(tiles, lightTile(index, light.name or ("Light " .. index), subtitle, selectedLight == index, light.on == true))
  end
  return ui.column({ gap = 8, padding = 12, fill = "surface", radius = 12, border = "outline", borderWidth = 1, align = "stretch" }, {
    ui.label({ text = "SELECT LIGHT", fontSize = 9, fontWeight = "medium", color = "on_surface_variant" }),
    ui.row({ gap = 8, align = "stretch" }, tiles),
  })
end

local function preview()
  if selectedDevice == "classic" then
    return classicPreview()
  end
  if selectedDevice == "plus" then
    return plusPreview()
  end
  if selectedDevice == "pedal" then
    return pedalPreview()
  end
  if selectedDevice == "wave" then
    return wavePreview()
  end
  return lightsPreview()
end

local function actionButtons(current)
  local matches = editor.filterCatalog(catalog, filter, current, 0)
  local children = {}
  for _, item in ipairs(matches) do
    local selected = item.action == current
    table.insert(children, ui.button({
      key = "act-" .. item.action,
      text = item.label ~= "" and item.label or item.action,
      variant = selected and "primary" or "outline",
      controlSize = "sm",
      contentAlign = "start",
      onClick = function()
        if selectedDevice == "wave" or selectedDevice == "lights" then
          return
        end
        saveAction(item.action, selectedSlot)
      end,
    }))
  end
  if #children == 0 then
    table.insert(children, ui.label({ text = "No matching actions.", color = "on_surface_variant", fontSize = 11 }))
  end
  return children
end

local function inspectorBody()
  local body = {
    ui.label({ text = "ACTION INSPECTOR", fontSize = 10, fontWeight = "medium", color = "on_surface_variant" }),
    ui.label({ text = editor.inspectorTitle(selectedDevice, selectedControl, selectedIndex, status.wave), fontSize = 16, fontWeight = "bold" }),
  }

  if selectedDevice == "wave" then
    table.insert(body, ui.label({ text = "MICROPHONE GAIN", fontSize = 9, fontWeight = "medium", color = "on_surface_variant" }))
    table.insert(body, ui.row({ gap = 8 }, {
      ui.button({ text = "Gain −", onClick = function() runHelper(editor.waveArgv(helper, "gain-down"), refresh) end }),
      ui.button({ text = "Gain +", onClick = function() runHelper(editor.waveArgv(helper, "gain-up"), refresh) end }),
    }))
    table.insert(body, ui.button({
      text = (status.wave and status.wave.muted) and "Unmute microphone" or "Mute microphone",
      onClick = function() runHelper(editor.waveArgv(helper, "mute"), refresh) end,
    }))
    table.insert(body, ui.label({ text = "HEADPHONES", fontSize = 9, fontWeight = "medium", color = "on_surface_variant" }))
    table.insert(body, ui.row({ gap = 8 }, {
      ui.button({ text = "HP −", onClick = function() runHelper(editor.waveArgv(helper, "headphone-down"), refresh) end }),
      ui.button({ text = "HP mute", onClick = function() runHelper(editor.waveArgv(helper, "headphone-mute"), refresh) end }),
      ui.button({ text = "HP +", onClick = function() runHelper(editor.waveArgv(helper, "headphone-up"), refresh) end }),
    }))
    table.insert(body, ui.label({ text = "GAIN PRESETS", fontSize = 9, fontWeight = "medium", color = "on_surface_variant" }))
    table.insert(body, ui.row({ gap = 8 }, {
      ui.button({ text = "Quiet", onClick = function() runHelper(editor.waveArgv(helper, "preset-quiet"), refresh) end }),
      ui.button({ text = "Normal", onClick = function() runHelper(editor.waveArgv(helper, "preset-normal"), refresh) end }),
      ui.button({ text = "Loud", onClick = function() runHelper(editor.waveArgv(helper, "preset-loud"), refresh) end }),
    }))
    table.insert(body, ui.button({
      text = "Use as default microphone",
      variant = "primary",
      onClick = function() runHelper(editor.waveArgv(helper, "default"), refresh) end,
    }))
    return body
  end

  if selectedDevice == "lights" then
    local lights = status.lights or {}
    local target = selectedLight == 0 and "all" or tostring(selectedLight - 1)
    local brightness = 40
    local kelvin = 5000
    local reachable = false
    local on = false
    local function consider(light)
      if type(light) == "table" and light.reachable then
        reachable = true
        if light.on then
          on = true
        end
        if light.brightness ~= nil then
          brightness = tonumber(light.brightness) or brightness
        end
        kelvin = editor.kelvin(light.temperature, kelvin)
      end
    end
    if selectedLight == 0 then
      for _, light in ipairs(lights) do
        consider(light)
      end
    else
      consider(lights[selectedLight])
    end
    lightBrightness = brightness
    lightKelvin = kelvin
    table.insert(body, ui.label({
      text = reachable and (on and "ON · REACHABLE" or "OFF · REACHABLE") or "UNAVAILABLE",
      fontSize = 9,
      fontWeight = "medium",
      color = reachable and "primary" or "error",
    }))
    table.insert(body, ui.row({ gap = 8 }, {
      ui.button({ text = "On", enabled = reachable, onClick = function() runHelper(editor.lightsArgv(helper, "on", target), refresh) end }),
      ui.button({ text = "Off", enabled = reachable, onClick = function() runHelper(editor.lightsArgv(helper, "off", target), refresh) end }),
    }))
    table.insert(body, ui.label({ text = "BRIGHTNESS " .. tostring(lightBrightness) .. "%", fontSize = 9, color = "on_surface_variant" }))
    table.insert(body, ui.slider({
      min = 1,
      max = 100,
      step = 1,
      value = lightBrightness,
      enabled = reachable,
      onChange = function(value)
        lightBrightness = tonumber(value) or lightBrightness
      end,
      onDragEnd = function()
        runHelper(editor.lightsArgv(helper, "brightness", target, lightBrightness), refresh)
      end,
    }))
    table.insert(body, ui.label({ text = "TEMPERATURE " .. tostring(lightKelvin) .. "K", fontSize = 9, color = "on_surface_variant" }))
    table.insert(body, ui.slider({
      min = 2900,
      max = 7000,
      step = 100,
      value = lightKelvin,
      enabled = reachable,
      onChange = function(value)
        lightKelvin = tonumber(value) or lightKelvin
      end,
      onDragEnd = function()
        runHelper(editor.lightsArgv(helper, "temperature", target, lightKelvin), refresh)
      end,
    }))
    table.insert(body, ui.button({
      text = "Refresh lights",
      onClick = function() runHelper(editor.lightsArgv(helper, "refresh", target), refresh) end,
    }))
    return body
  end

  table.insert(body, ui.label({
    text = "Choose a function, key, or installed app. Changes apply immediately.",
    fontSize = 11,
    color = "on_surface_variant",
  }))

  if selectedControl == "dial" then
    local headings = { left = "Turn left", press = "Press", right = "Turn right" }
    for _, slot in ipairs({ "left", "press", "right" }) do
      local mapped = editor.dialSlot(editor.keysFor(profile, "plus-dials"), selectedIndex, slot)
      table.insert(body, ui.button({
        key = "slot-" .. slot,
        text = headings[slot] .. " · " .. editor.shortLabel({ action = mapped }),
        variant = selectedSlot == slot and "primary" or "outline",
        controlSize = "sm",
        contentAlign = "start",
        onClick = function()
          selectedSlot = slot
          paint()
        end,
      }))
    end
  end

  table.insert(body, ui.input({
    key = "filter",
    placeholder = "Filter actions…",
    onChange = function(value)
      filter = value or ""
      paint()
    end,
  }))
  for _, child in ipairs(actionButtons(currentMappedAction())) do
    table.insert(body, child)
  end
  return body
end

local function inspector()
  local body = inspectorBody()
  if status.lastAction then
    table.insert(body, ui.label({
      text = "Last action: " .. tostring(status.lastAction) .. " · " .. tostring(status.lastEvent or ""),
      fontSize = 10,
      color = "on_surface_variant",
    }))
  end
  if errorText ~= "" or (status.error or "") ~= "" then
    table.insert(body, ui.label({
      text = errorText ~= "" and errorText or status.error,
      color = "error",
      fontSize = 11,
    }))
  end
  return ui.scroll({
    flexGrow = 1,
    gap = 10,
    padding = 12,
    fill = "surface",
    radius = 12,
    border = "outline",
    borderWidth = 1,
  }, body)
end

local function connectionLabel()
  if not caps().connected then
    return "Disconnected"
  end
  local parts = {}
  if type(status.classic) == "table" then
    table.insert(parts, status.classic.product or "Stream Deck")
  end
  if type(status.plus) == "table" then
    table.insert(parts, status.plus.product or "Stream Deck +")
  end
  if type(status.pedal) == "table" then
    table.insert(parts, status.pedal.product or "Pedal")
  end
  if type(status.wave) == "table" then
    table.insert(parts, status.wave.product or "Wave")
  end
  if #parts == 0 then
    return "Connected"
  end
  return table.concat(parts, " · ")
end

tree = function()
  local connected = caps().connected
  return ui.column({ flexGrow = 1, gap = 14, align = "stretch" }, {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.row({ gap = 10, align = "center", flexGrow = 1 }, {
        ui.image({ path = "assets/elgato.svg", width = 22, height = 22 }),
        ui.column({ gap = 2 }, {
          ui.label({ text = "Elgato Control", fontSize = 16, fontWeight = "bold" }),
          ui.label({ text = status.profile or "Noctalia Default", fontSize = 11, color = "on_surface_variant" }),
        }),
      }),
      ui.label({
        text = connectionLabel(),
        color = connected and "primary" or "on_surface_variant",
        fontSize = 11,
      }),
      ui.button({ glyph = "close", onClick = function() panel.close() end }),
    }),
    deviceButtons(),
    ui.row({ gap = 14, align = "stretch", flexGrow = 1 }, {
      ui.column({ flexGrow = 1, align = "stretch" }, { preview() }),
      ui.column({ width = 300, align = "stretch" }, { inspector() }),
    }),
  })
end

function onOpen(_context)
  open = true
  errorText = ""
  refresh()
  paint()
end

function onClose()
  open = false
end

function update()
  noctalia.setUpdateInterval(1500)
  if open then
    refresh()
  end
end
