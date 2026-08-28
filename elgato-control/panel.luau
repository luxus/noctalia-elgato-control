--!nonstrict
local helper = (noctalia.pluginDir() or ".") .. "/bin/elgato-control"
local status = { running = false, plus = nil, classic = nil, pedal = nil, wave = nil, lights = {}, profile = "Noctalia Default" }
local profile = { keys = {}, classicKeys = {}, dials = {}, pedals = {} }
local catalog = {}
local catalogLabels = {}
local selectedDevice = "classic"
local selectedControl = "key"
local selectedIndex = 1
local selectedLight = 0
local filter = ""
local errorText = ""

local function quote(path)
  return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

local function hasClassic()
  return status.classic ~= nil
end

local function hasPlus()
  return status.plus ~= nil
end

local function hasPedal()
  return status.pedal ~= nil
end

local function hasWave()
  return status.wave ~= nil
end

local function hasLights()
  local lights = status.lights or {}
  for _, light in ipairs(lights) do
    if light.reachable then
      return true
    end
  end
  return false
end

local function connected()
  return hasClassic() or hasPlus() or hasPedal()
end

local function labelFor(action)
  if catalogLabels[action] then
    return catalogLabels[action]
  end
  if action == nil or action == "" then
    return "Unassigned"
  end
  return tostring(action)
end

local function currentKeys()
  if selectedDevice == "classic" then
    return profile.classicKeys or {}
  end
  return profile.keys or {}
end

local function currentAction()
  if selectedDevice == "pedal" then
    local pedal = (profile.pedals or {})[selectedIndex] or {}
    return pedal.action or ""
  end
  if selectedControl == "dial" then
    return ""
  end
  local key = currentKeys()[selectedIndex] or {}
  return key.action or ""
end

local function refresh()
  noctalia.runAsync(quote(helper) .. " status --json", function(result)
    if result.exitCode == 0 and result.stdout ~= "" then
      local parsed = noctalia.json.decode(result.stdout)
      if type(parsed) == "table" then
        status = parsed
        if selectedDevice == "classic" and not hasClassic() and hasPlus() then
          selectedDevice = "plus"
        elseif selectedDevice == "plus" and not hasPlus() and hasClassic() then
          selectedDevice = "classic"
        end
      end
    end
    render()
  end)
  noctalia.runAsync(quote(helper) .. " profile", function(result)
    if result.exitCode == 0 and result.stdout ~= "" then
      local parsed = noctalia.json.decode(result.stdout)
      if type(parsed) == "table" then
        profile = parsed
      end
    end
    render()
  end)
  if #catalog == 0 then
    noctalia.runAsync(quote(helper) .. " catalog", function(result)
      if result.exitCode == 0 and result.stdout ~= "" then
        local parsed = noctalia.json.decode(result.stdout)
        if type(parsed) == "table" then
          catalog = parsed
          catalogLabels = {}
          for _, item in ipairs(catalog) do
            local label = item.label or item.value
            catalogLabels[item.value] = (label:gsub("^(Function|Application|Key) · ", ""))
          end
        end
      end
      render()
    end)
  end
end

local function saveAction(slot, action)
  local command
  if selectedDevice == "classic" and selectedControl == "key" then
    command = quote(helper) .. " set-key --device classic " .. tostring(selectedIndex) .. " " .. quote(action)
  elseif selectedDevice == "plus" and selectedControl == "key" then
    command = quote(helper) .. " set-key --device plus " .. tostring(selectedIndex) .. " " .. quote(action)
  elseif selectedDevice == "plus" and selectedControl == "dial" then
    command = quote(helper) .. " set-dial " .. tostring(selectedIndex) .. " " .. slot .. " " .. quote(action)
  elseif selectedDevice == "pedal" then
    command = quote(helper) .. " set-pedal " .. tostring(selectedIndex) .. " " .. quote(action)
  else
    return
  end
  noctalia.runAsync(command, function(result)
    if result.exitCode ~= 0 then
      errorText = result.stderr ~= "" and result.stderr or "Could not save action"
    else
      errorText = ""
    end
    refresh()
  end)
end

local function waveAction(action)
  noctalia.runAsync(quote(helper) .. " wave " .. action, function()
    refresh()
  end)
end

local function lightAction(action, value)
  local target = selectedLight == 0 and "all" or tostring(selectedLight - 1)
  local command = quote(helper) .. " lights " .. action .. " --target " .. target
  if value ~= nil then
    command = command .. " --value " .. tostring(math.floor(value))
  end
  noctalia.runAsync(command, function()
    refresh()
  end)
end

local function keyTile(index, key, cols)
  local selected = selectedControl == "key" and selectedIndex == index
  local action = (key or {}).action or ""
  return ui.box({
    key = "key-" .. tostring(index),
    fill = selected and "surface_variant" or "surface",
    border = selected and "primary" or "outline",
    borderWidth = selected and 2 or 1,
    radius = 8,
    flexGrow = 1,
    minHeight = cols == 5 and 56 or 72,
    onClick = function()
      selectedControl = "key"
      selectedIndex = index
      render()
    end,
  }, {
    ui.column({ gap = 2, padding = 6, align = "center" }, {
      ui.label({ text = tostring(index), fontSize = 9, color = "on_surface_variant" }),
      ui.label({
        text = labelFor(action),
        fontSize = 10,
        color = "on_surface",
        maxLines = 2,
        textAlign = "center",
      }),
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
  for index, dial in ipairs(profile.dials or {}) do
    local selected = selectedControl == "dial" and selectedIndex == index
    table.insert(children, ui.column({ gap = 4, align = "center", flexGrow = 1 }, {
      ui.label({ text = dial.label or ("Dial " .. index), fontSize = 9, color = "on_surface_variant", maxLines = 1 }),
      ui.button({
        text = tostring(index),
        variant = selected and "primary" or "outline",
        onClick = function()
          selectedControl = "dial"
          selectedIndex = index
          render()
        end,
      }),
    }))
  end
  return ui.row({ gap = 8, align = "center" }, children)
end

local function deviceButtons()
  local buttons = {}
  local function add(id, label, visible)
    if not visible then
      return
    end
    table.insert(buttons, ui.button({
      text = label,
      variant = selectedDevice == id and "primary" or "outline",
      controlSize = "sm",
      onClick = function()
        selectedDevice = id
        selectedIndex = 1
        selectedControl = (id == "plus" or id == "classic") and "key" or id
        selectedLight = 0
        render()
      end,
    }))
  end
  add("classic", "Stream Deck", hasClassic() or not connected())
  add("plus", "Stream Deck +", hasPlus() or not connected())
  add("pedal", "Pedal", hasPedal())
  add("wave", "Wave:3", hasWave())
  add("lights", "Key Lights", hasLights())
  return ui.row({ gap = 8, align = "center" }, buttons)
end

local function preview()
  if selectedDevice == "classic" then
    return ui.column({ gap = 10, padding = 12, fill = "surface", radius = 12, border = "outline", borderWidth = 1, align = "stretch" }, {
      ui.label({ text = "STREAM DECK · 5×3", fontSize = 10, fontWeight = "medium", color = "on_surface_variant" }),
      keyGrid(profile.classicKeys or {}, 5),
    })
  end
  if selectedDevice == "plus" then
    return ui.column({ gap = 10, padding = 12, fill = "surface", radius = 12, border = "outline", borderWidth = 1, align = "stretch" }, {
      ui.label({ text = "STREAM DECK + · 4×2", fontSize = 10, fontWeight = "medium", color = "on_surface_variant" }),
      keyGrid(profile.keys or {}, 4),
      ui.box({ height = 44, fill = "surface_variant", radius = 8, border = "outline", borderWidth = 1 }, {
        ui.row({ padding = 8, justify = "space_between", align = "center" }, {
          ui.label({ text = "LCD STRIP", fontSize = 9, color = "on_surface_variant" }),
          ui.label({ text = tostring(status.brightness or 55) .. "% backlight", fontSize = 9, color = "on_surface_variant" }),
        }),
      }),
      dialRow(),
    })
  end
  if selectedDevice == "pedal" then
    local children = {}
    local names = { "LEFT", "MIDDLE", "RIGHT" }
    for index, pedal in ipairs(profile.pedals or {}) do
      table.insert(children, ui.button({
        text = names[index] .. "\n" .. labelFor(pedal.action),
        variant = selectedIndex == index and "primary" or "outline",
        flexGrow = 1,
        onClick = function()
          selectedControl = "pedal"
          selectedIndex = index
          render()
        end,
      }))
    end
    return ui.row({ gap = 10, padding = 12, fill = "surface", radius = 12, border = "outline", borderWidth = 1 }, children)
  end
  if selectedDevice == "wave" then
    local wave = status.wave or {}
    return ui.column({ gap = 8, padding = 16, fill = "surface", radius = 12, border = "outline", borderWidth = 1, align = "center" }, {
      ui.glyph({ name = "microphone", size = 36, color = wave.muted and "error" or "primary" }),
      ui.label({ text = wave.product or "Wave microphone", fontWeight = "bold" }),
      ui.label({ text = wave.muted and "MUTED" or "LIVE", color = wave.muted and "error" or "primary", fontSize = 11 }),
      ui.progress({ progress = (wave.gainPercent or 0) / 100, width = "fill", height = 8 }),
      ui.label({ text = "Gain " .. tostring(wave.gainDb or "--") .. " dB · HP " .. tostring(wave.headphonePercent or "--") .. "%", fontSize = 11, color = "on_surface_variant" }),
    })
  end
  local lights = status.lights or {}
  local tiles = {
    ui.button({
      text = "All lights",
      variant = selectedLight == 0 and "primary" or "outline",
      onClick = function()
        selectedLight = 0
        render()
      end,
    }),
  }
  for index, light in ipairs(lights) do
    table.insert(tiles, ui.button({
      text = (light.name or "Light") .. (light.reachable and "" or " · off-line"),
      variant = selectedLight == index and "primary" or "outline",
      onClick = function()
        selectedLight = index
        render()
      end,
    }))
  end
  return ui.column({ gap = 8, padding = 12, fill = "surface", radius = 12, border = "outline", borderWidth = 1, align = "stretch" }, tiles)
end

local function actionChoices()
  local options = {}
  local values = {}
  local needle = string.lower(filter)
  for _, item in ipairs(catalog) do
    local label = item.label or item.value
    if needle == "" or string.find(string.lower(label), needle, 1, true) then
      table.insert(options, label)
      table.insert(values, item.value)
    end
    if #options >= 40 then
      break
    end
  end
  return options, values
end

local function selectIndexFor(action, values)
  for index, value in ipairs(values) do
    if value == action then
      return index - 1
    end
  end
  return 0
end

local function inspector()
  local title = "Action inspector"
  if selectedDevice == "classic" or selectedDevice == "plus" then
    title = (selectedControl == "dial" and "Dial " or "Key ") .. tostring(selectedIndex)
  elseif selectedDevice == "pedal" then
    title = ({ "Left pedal", "Middle pedal", "Right pedal" })[selectedIndex] or "Pedal"
  elseif selectedDevice == "wave" then
    title = "Wave:3"
  else
    title = selectedLight == 0 and "All Key Lights" or "Key Light"
  end

  local body = {}
  table.insert(body, ui.label({ text = "ACTION INSPECTOR", fontSize = 10, fontWeight = "medium", color = "on_surface_variant" }))
  table.insert(body, ui.label({ text = title, fontSize = 16, fontWeight = "bold" }))

  if selectedDevice == "wave" then
    table.insert(body, ui.row({ gap = 8 }, {
      ui.button({ text = "Gain −", onClick = function() waveAction("gain-down") end }),
      ui.button({ text = "Gain +", onClick = function() waveAction("gain-up") end }),
    }))
    table.insert(body, ui.button({ text = "Mute microphone", onClick = function() waveAction("mute") end }))
    table.insert(body, ui.row({ gap = 8 }, {
      ui.button({ text = "HP −", onClick = function() waveAction("headphone-down") end }),
      ui.button({ text = "HP mute", onClick = function() waveAction("headphone-mute") end }),
      ui.button({ text = "HP +", onClick = function() waveAction("headphone-up") end }),
    }))
    table.insert(body, ui.row({ gap = 8 }, {
      ui.button({ text = "Quiet", onClick = function() waveAction("preset-quiet") end }),
      ui.button({ text = "Normal", onClick = function() waveAction("preset-normal") end }),
      ui.button({ text = "Loud", onClick = function() waveAction("preset-loud") end }),
    }))
    table.insert(body, ui.button({ text = "Use as default microphone", variant = "primary", onClick = function() waveAction("default") end }))
  elseif selectedDevice == "lights" then
    table.insert(body, ui.row({ gap = 8 }, {
      ui.button({ text = "On", onClick = function() lightAction("on") end }),
      ui.button({ text = "Off", onClick = function() lightAction("off") end }),
    }))
    table.insert(body, ui.button({ text = "Refresh lights", onClick = function() lightAction("refresh") end }))
  elseif selectedControl == "dial" then
    local dial = (profile.dials or {})[selectedIndex] or {}
    local options, values = actionChoices()
    local function picker(slot, heading)
      table.insert(body, ui.label({ text = heading, fontSize = 11, color = "on_surface_variant" }))
      table.insert(body, ui.select({
        options = options,
        selectedIndex = selectIndexFor(dial[slot], values),
        onChange = function(index)
          local value = values[(tonumber(index) or 0) + 1]
          if value then
            saveAction(slot, value)
          end
        end,
      }))
    end
    picker("left", "Turn left")
    picker("press", "Press")
    picker("right", "Turn right")
  else
    table.insert(body, ui.label({ text = "Choose a function, key, or installed app. Changes apply immediately.", fontSize = 11, color = "on_surface_variant" }))
    table.insert(body, ui.input({
      key = "filter",
      placeholder = "Filter actions…",
      onChange = function(value)
        filter = value or ""
        render()
      end,
    }))
    local options, values = actionChoices()
    table.insert(body, ui.select({
      options = options,
      selectedIndex = selectIndexFor(currentAction(), values),
      onChange = function(index)
        local value = values[(tonumber(index) or 0) + 1]
        if value then
          saveAction("action", value)
        end
      end,
    }))
  end

  if status.lastAction then
    table.insert(body, ui.label({ text = "Last action: " .. tostring(status.lastAction) .. " · " .. tostring(status.lastEvent or ""), fontSize = 10, color = "on_surface_variant" }))
  end
  if errorText ~= "" or (status.error or "") ~= "" then
    table.insert(body, ui.label({ text = errorText ~= "" and errorText or status.error, color = "error", fontSize = 11 }))
  end

  return ui.column({ gap = 10, padding = 12, fill = "surface", radius = 12, border = "outline", borderWidth = 1, align = "stretch", flexGrow = 1 }, body)
end

function render()
  panel.render(ui.column({ flexGrow = 1, gap = 14, align = "stretch" }, {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.row({ gap = 10, align = "center" }, {
        ui.image({ path = "assets/elgato.svg", width = 22, height = 22 }),
        ui.column({ gap = 2 }, {
          ui.label({ text = "Elgato Control", fontSize = 16, fontWeight = "bold" }),
          ui.label({ text = status.profile or "Noctalia Default", fontSize = 11, color = "on_surface_variant" }),
        }),
      }),
      ui.label({
        text = connected() and "Connected" or "Disconnected",
        color = connected() and "primary" or "on_surface_variant",
        fontSize = 11,
      }),
    }),
    deviceButtons(),
    ui.row({ gap = 14, align = "stretch", flexGrow = 1 }, {
      ui.box({ flexGrow = 1 }, { preview() }),
      ui.box({ width = 280 }, { inspector() }),
    }),
  }))
end

function onOpen(_context)
  refresh()
  render()
end

function update()
  noctalia.setUpdateInterval(1500)
  refresh()
end
