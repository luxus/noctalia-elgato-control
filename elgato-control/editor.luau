--!nonstrict
-- Visual editor state for the Elgato panel (Omarchy-style, Noctalia v5 Luau).
-- Pure module: no noctalia globals. plugin_api 24 `require("./editor.luau")`.

local editor = {}

local function present(value)
	return type(value) == "table" or value == true
end

function editor.catalogAction(item)
	if type(item) ~= "table" then
		return tostring(item or "")
	end
	if type(item.action) == "string" and item.action ~= "" then
		return item.action
	end
	if type(item.value) == "string" and item.value ~= "" then
		return item.value
	end
	return ""
end

function editor.displayLabel(item)
	if type(item) ~= "table" then
		return tostring(item or "")
	end
	if type(item.label) == "string" and item.label ~= "" then
		return item.label
	end
	return editor.catalogAction(item)
end

function editor.shortLabel(item)
	local label = editor.displayLabel(item)
	return (label:gsub("^(Function|Application|Key) · ", ""))
end

function editor.normalizeCatalog(catalog)
	local out = {}
	for _, item in ipairs(catalog or {}) do
		local action = editor.catalogAction(item)
		if action ~= "" then
			table.insert(out, { action = action, label = editor.shortLabel(item) })
		end
	end
	return out
end

function editor.capabilities(status)
	status = status or {}
	local keylight = false
	for _, light in ipairs(status.lights or {}) do
		if type(light) == "table" and light.reachable then
			keylight = true
			break
		end
	end
	local plus = present(status.plus)
	local classic = present(status.classic)
	local pedal = present(status.pedal)
	local wave = present(status.wave)
	return {
		plus = plus,
		classic = classic,
		pedal = pedal,
		wave = wave,
		keylight = keylight,
		connected = plus or classic or pedal,
	}
end

function editor.deviceTabs(caps)
	caps = caps or {}
	local tabs = {}
	if caps.classic then
		table.insert(tabs, "classic")
	end
	if caps.plus then
		table.insert(tabs, "plus")
	end
	if caps.pedal then
		table.insert(tabs, "pedal")
	end
	if caps.wave then
		table.insert(tabs, "wave")
	end
	if caps.keylight then
		table.insert(tabs, "lights")
	end
	if #tabs == 0 then
		-- Disconnected: still edit classic 15-key + Plus profiles (lea).
		tabs = { "classic", "plus" }
	end
	return tabs
end

function editor.tabLabel(id)
	local labels = {
		classic = "Stream Deck",
		plus = "Stream Deck +",
		pedal = "Pedal",
		wave = "Wave:3",
		lights = "Key Lights",
	}
	return labels[id] or id
end

function editor.pickDevice(tabs, current)
	if current ~= nil then
		for _, tab in ipairs(tabs) do
			if tab == current then
				return current
			end
		end
	end
	return tabs[1]
end

function editor.keysFor(profile, device)
	profile = profile or {}
	if device == "classic" then
		return profile.classicKeys or {}
	end
	if device == "plus" then
		return profile.keys or {}
	end
	if device == "pedal" then
		return profile.pedals or {}
	end
	if device == "plus-dials" then
		return profile.dials or {}
	end
	return {}
end

function editor.padKeys(keys, count, fallback)
	local out = {}
	for i = 1, count do
		local item = keys[i]
		if type(item) == "table" then
			out[i] = item
		else
			out[i] = { action = fallback or "none" }
		end
	end
	return out
end

function editor.currentAction(keys, index)
	local item = keys[index]
	if type(item) == "table" and type(item.action) == "string" and item.action ~= "" then
		return item.action
	end
	return "none"
end

function editor.dialSlot(dials, index, slot)
	local item = dials[index]
	if type(item) == "table" and type(item[slot]) == "string" and item[slot] ~= "" then
		return item[slot]
	end
	return "none"
end

-- CLI is 1-based. `control` is key | dial | pedal. Dial `slot` is left | press | right.
function editor.saveArgv(helper, device, control, index, action, slot)
	if control == "dial" then
		return { helper, "set-dial", tostring(index), slot or "press", action }
	end
	if control == "pedal" then
		return { helper, "set-pedal", tostring(index), action }
	end
	if device == "classic" then
		return { helper, "set-key", "--device", "classic", tostring(index), action }
	end
	return { helper, "set-key", "--device", "plus", tostring(index), action }
end

function editor.waveArgv(helper, action)
	return { helper, "wave", action }
end

function editor.lightsArgv(helper, action, target, value)
	local argv = { helper, "lights", action, "--target", target or "all" }
	if value ~= nil then
		table.insert(argv, "--value")
		table.insert(argv, tostring(math.floor(value)))
	end
	return argv
end

function editor.filterCatalog(catalog, query, currentAction, limit)
	catalog = catalog or {}
	limit = limit or 80
	query = string.lower(query or "")
	local matches = {}
	local seen = {}

	local function push(item)
		local action = editor.catalogAction(item)
		if action == "" or seen[action] then
			return false
		end
		seen[action] = true
		table.insert(matches, { action = action, label = editor.shortLabel(item) })
		return #matches >= limit
	end

	if currentAction ~= nil and currentAction ~= "" then
		local found = false
		for _, item in ipairs(catalog) do
			if editor.catalogAction(item) == currentAction then
				if push(item) then
					return matches
				end
				found = true
				break
			end
		end
		if not found then
			if push({ action = currentAction, label = currentAction }) then
				return matches
			end
		end
	end

	for _, item in ipairs(catalog) do
		if query == "" then
			if push(item) then
				return matches
			end
		else
			local hay = string.lower(editor.catalogAction(item) .. " " .. editor.shortLabel(item))
			if string.find(hay, query, 1, true) then
				if push(item) then
					return matches
				end
			end
		end
	end
	return matches
end

function editor.inspectorTitle(device, control, index)
	if device == "wave" then
		return "Wave:3"
	end
	if device == "lights" then
		return "Key Light"
	end
	if control == "dial" then
		return "Plus dial " .. tostring(index)
	end
	if control == "pedal" then
		local names = { "Left pedal", "Middle pedal", "Right pedal" }
		return names[index] or ("Pedal " .. tostring(index))
	end
	if device == "classic" then
		return "Classic key " .. tostring(index)
	end
	return "Plus key " .. tostring(index)
end

function editor.selection(device, control, index)
	return {
		device = device,
		control = control or "key",
		index = index,
	}
end

function editor.kelvin(mireds, fallback)
	local value = tonumber(mireds)
	if not value or value <= 0 then
		return fallback or 5000
	end
	return math.floor((1000000 / value) + 0.5)
end

return editor
