--!nonstrict
local connected = noctalia.state.get("connected") == true

local function render()
  shortcut.setLabel("Elgato")
  shortcut.setIcon("keyboard")
  shortcut.setActive(connected)
end

noctalia.state.watch("connected", function(value)
  connected = value == true
  render()
end)

render()

function onClick()
  noctalia.togglePanel("luxus/elgato-control:panel")
end
