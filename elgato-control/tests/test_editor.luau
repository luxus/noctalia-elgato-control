-- Panel/editor state machine: select key → set action → profile argv → status.
-- nixpkgs luau has no Noctalia require() and no io. flake check concatenates
-- editor.luau (without `return editor`) in front of this file so `editor` is in scope.
local failed = 0

local function check(name, cond)
	if cond then
		print("ok - " .. name)
	else
		failed = failed + 1
		print("not ok - " .. name)
	end
end

-- Disconnected: still show classic + plus so the profile can be edited.
local tabsOff = editor.deviceTabs(editor.capabilities({}))
check("disconnected tabs include classic", tabsOff[1] == "classic")
check("disconnected tabs include plus", tabsOff[2] == "plus")
check("disconnected has no pedal/wave/lights", #tabsOff == 2)

-- Daemon status uses objects, not booleans.
local capsOn = editor.capabilities({
	plus = { product = "Stream Deck +", keys = 8 },
	classic = { product = "Stream Deck Mk.2", keys = 15 },
	pedal = { product = "Stream Deck Pedal" },
	wave = { product = "Wave:3", muted = false },
	lights = { { name = "Key Light", reachable = true, on = true, brightness = 40, temperature = 200 } },
})
local tabsOn = editor.deviceTabs(capsOn)
check("plus present from object", capsOn.plus)
check("classic present from object", capsOn.classic)
check("connected when a deck is present", capsOn.connected)
check("pedal tab only when present", tabsOn[3] == "pedal")
check("wave tab only when present", tabsOn[4] == "wave")
check("lights tab only when a light is reachable", tabsOn[5] == "lights")
check("no lights tab when lights are offline", editor.deviceTabs(editor.capabilities({
	plus = { product = "Stream Deck +" },
	lights = { { name = "Key Light", reachable = false } },
}))[1] == "plus")
check("unreachable-only lights do not add a tab", #editor.deviceTabs(editor.capabilities({
	plus = { product = "Stream Deck +" },
	lights = { { name = "Key Light", reachable = false } },
})) == 1)

check("pick keeps current", editor.pickDevice({ "classic", "plus" }, "plus") == "plus")
check("pick falls back", editor.pickDevice({ "classic", "plus" }, "pedal") == "classic")
check("tab label classic", editor.tabLabel("classic") == "Stream Deck")

local profile = {
	keys = { { action = "lock" }, { action = "launcher" } },
	classicKeys = {},
	dials = { { label = "Volume", left = "volume_down", press = "volume_mute", right = "volume_up" } },
	pedals = { { action = "mic_mute" }, { action = "none" }, { action = "screenshot" } },
}
for i = 1, 15 do
	profile.classicKeys[i] = { action = "none" }
end
profile.classicKeys[1] = { action = "terminal" }
profile.classicKeys[15] = { action = "launcher" }

local classic = editor.padKeys(editor.keysFor(profile, "classic"), 15, "none")
check("classic pad 15", #classic == 15)
check("classic key 1", editor.currentAction(classic, 1) == "terminal")
check("classic key 15 launcher", editor.currentAction(classic, 15) == "launcher")
check("classic missing is none", editor.currentAction(classic, 8) == "none")

local plus = editor.padKeys(editor.keysFor(profile, "plus"), 8, "none")
check("plus pad 8", #plus == 8)
check("plus key 1 lock", editor.currentAction(plus, 1) == "lock")

check("pedal 1 mute", editor.currentAction(editor.keysFor(profile, "pedal"), 1) == "mic_mute")
check("dial press volume_mute", editor.dialSlot(editor.keysFor(profile, "plus-dials"), 1, "press") == "volume_mute")
check("dial left volume_down", editor.dialSlot(editor.keysFor(profile, "plus-dials"), 1, "left") == "volume_down")

-- Select classic key 1 → set lock → CLI argv (1-based).
local sel = editor.selection("classic", "key", 1)
check("selection device", sel.device == "classic" and sel.index == 1)
local argv = editor.saveArgv("/plugin/bin/elgato-control", sel.device, sel.control, sel.index, "lock")
check("set-key classic argv", argv[2] == "set-key" and argv[4] == "classic" and argv[5] == "1" and argv[6] == "lock")

local plusArgv = editor.saveArgv("elgato-control", "plus", "key", 3, "browser")
check("set-key plus argv", plusArgv[4] == "plus" and plusArgv[5] == "3" and plusArgv[6] == "browser")

local dialArgv = editor.saveArgv("elgato-control", "plus", "dial", 2, "mic_mute", "press")
check("set-dial argv includes slot", dialArgv[2] == "set-dial" and dialArgv[3] == "2" and dialArgv[4] == "press" and dialArgv[5] == "mic_mute")

local pedalArgv = editor.saveArgv("elgato-control", "pedal", "pedal", 3, "screenshot")
check("set-pedal argv", pedalArgv[2] == "set-pedal" and pedalArgv[3] == "3" and pedalArgv[4] == "screenshot")

check("wave argv", editor.waveArgv("elgato-control", "mute")[2] == "wave")
local lightArgv = editor.lightsArgv("elgato-control", "brightness", "all", 40)
check("lights argv value", lightArgv[3] == "brightness" and lightArgv[7] == "40")

-- Catalog from the Python CLI uses `value`, not `action`.
local catalog = editor.normalizeCatalog({
	{ value = "none", label = "Function · Unassigned" },
	{ value = "lock", label = "Function · Lock Screen" },
	{ value = "launcher", label = "Function · Open Launcher" },
	{ value = "niri_close", label = "Function · Close Window" },
	{ value = "app:firefox.desktop", label = "Application · Firefox" },
})
check("normalize strips Function prefix", catalog[2].label == "Lock Screen")
check("normalize keeps action id", catalog[2].action == "lock")

local filtered = editor.filterCatalog(catalog, "lock", "none", 80)
check("filter pins current action first", filtered[1].action == "none")
check("filter then match", filtered[2].action == "lock")
check("filter excludes unrelated", #filtered == 2)

local full = editor.filterCatalog(catalog, "", "lock", 80)
check("empty query keeps current first", full[1].action == "lock")
check("empty query then rest", #full == #catalog)

local missing = editor.filterCatalog(catalog, "", "app:obs.desktop", 80)
check("unknown current is injected", missing[1].action == "app:obs.desktop")

check("title classic", editor.inspectorTitle("classic", "key", 4) == "Classic key 4")
check("title plus dial", editor.inspectorTitle("plus", "dial", 2) == "Plus dial 2")
check("title pedal", editor.inspectorTitle("pedal", "pedal", 1) == "Left pedal")
check("title wave", editor.inspectorTitle("wave", "key", 0) == "Wave:3")
check("kelvin from mireds", editor.kelvin(200) == 5000)

if failed > 0 then
	error(string.format("%d editor checks failed", failed))
end
print("all editor checks passed")
