--!nonstrict
local showLabel = noctalia.getConfig("show_label") == true
local connected = noctalia.state.get("connected") == true
local product = noctalia.state.get("product") or ""

local function tooltip()
  if connected then
    if product ~= "" then
      return "Elgato Control · " .. product
    end
    return noctalia.tr("widget.connected")
  end
  return noctalia.tr("widget.disconnected")
end

local function render()
  barWidget.setImage("assets/elgato.svg")
  if showLabel then
    barWidget.setText(noctalia.tr("widget.label"))
  else
    barWidget.setText("")
  end
  barWidget.setTooltip(tooltip())
end

noctalia.state.watch("connected", function(value)
  connected = value == true
  render()
end)

noctalia.state.watch("product", function(value)
  product = value or ""
  render()
end)

function update()
  noctalia.setUpdateInterval(1500)
  render()
end

function onClick()
  noctalia.togglePanel("luxus/elgato-control:panel")
end
