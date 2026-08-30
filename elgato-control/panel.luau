--!nonstrict
-- Omarchy-style visual key/dial/pedal editor on Noctalia v5 (plugin_api 24).
-- Layout follows official-plugins/example/panel.luau: column/row/scroll only.
-- The box node is a leaf color swatch, not a flex parent — using it as a layout
-- parent produced a black panel on lea.

if type(panel) ~= "table" or type(panel.render) ~= "function" then
  error("Elgato Control: panel.render is missing. Need Noctalia v5 plugin_api 24. A black panel usually means the surface API never ran.")
end
if type(ui) ~= "table" then
  error("Elgato Control: ui namespace is missing.")
end
for _, name in ipairs({ "column", "row", "scroll", "label", "button", "input", "slider", "progress", "glyph", "image", "spacer" }) do
  if type(ui[name]) ~= "function" then
    error("Elgato Control: ui." .. name .. " is missing. Need Noctalia v5 declarative UI.")
  end
end
if type(noctalia) ~= "table" or type(noctalia.runAsync) ~= "function" then
  error("Elgato Control: noctalia.runAsync is missing.")
end
if type(noctalia.json) ~= "table" or type(noctalia.json.decode) ~= "function" then
  error("Elgato Control: noctalia.json.decode is missing.")
end

local editor = require("./editor.luau")
local helper = (noctalia.pluginDir() or ".") .. "/bin/elgato-control"
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
local tree

local function paint()
  if not open then
    return
  end
  panel.render(tree())
end

local function runHelper(argv, after)
  local launched = noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 then
      local err = result.stderr ~= "" and result.stderr or result.stdout
      errorText = (err ~= "" and err or "elgato-control failed")
      noctalia.log("elgato-control failed: " .. errorText)
    else
      errorText = ""
    end
    if after then
      after(result)
    end
    paint()
  end)
  if launched == false then
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

function refresh()
  if not open then
    return
  end
  runHelper({ helper, "status", "--json" }, function(result)
    if result.exitCode == 0 and result.stdout ~= "" then
      local parsed = noctalia.json.decode(result.stdout)
      if type(parsed) == "table" then
        status = parsed
        selectedDevice = editor.pickDevice(tabs(), selectedDevice)
      end
    end
  end)
  runHelper({ helper, "profile" }, function(result)
    if result.exitCode == 0 and result.stdout ~= "" then
      local parsed = noctalia.json.decode(result.stdout)
      if type(parsed) == "table" then
        profile = parsed
      end
    end
  end)
  if #catalog == 0 then
    runHelper({ helper, "catalog" }, function(result)
      if result.exitCode == 0 and result.stdout ~= "" then
        local parsed = noctalia.json.decode(result.stdout)
        if type(parsed) == "table" then
          catalog = editor.normalizeCatalog(parsed)
        end
      end
    end)
  end
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
  local argv = editor.saveArgv(helper, selectedDevice, selectedControl, selectedIndex, action, slot or selectedSlot)
  runHelper(argv, function()
    refresh()
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
      text = editor.tabLabel(id),
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
    ui.progress({ progress = math.max(0, math.min(1, (wave.gainPercent or 0) / 100)), width = "fill", height = 8 }),
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
  local matches = editor.filterCatalog(catalog, filter, current, 80)
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
    ui.label({ text = editor.inspectorTitle(selectedDevice, selectedControl, selectedIndex), fontSize = 16, fontWeight = "bold" }),
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
    table.insert(body, ui.label({ text = "BRIGHTNESS " .. tostring(brightness) .. "%", fontSize = 9, color = "on_surface_variant" }))
    table.insert(body, ui.slider({
      min = 1,
      max = 100,
      step = 1,
      value = brightness,
      enabled = reachable,
      onDragEnd = function(value)
        runHelper(editor.lightsArgv(helper, "brightness", target, tonumber(value) or brightness), refresh)
      end,
    }))
    table.insert(body, ui.label({ text = "TEMPERATURE " .. tostring(kelvin) .. "K", fontSize = 9, color = "on_surface_variant" }))
    table.insert(body, ui.slider({
      min = 2900,
      max = 7000,
      step = 100,
      value = kelvin,
      enabled = reachable,
      onDragEnd = function(value)
        runHelper(editor.lightsArgv(helper, "temperature", target, tonumber(value) or kelvin), refresh)
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

function tree()
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
        text = connected and "Connected" or "Disconnected",
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
