--[[
  OmniDeck for FrSky Ethos: picks the code for this radio's screen and starts it.

  Two separate copies of OmniDeck sit next to this file, so a change made for one radio
  can't affect the other:
    x18/  screens 480 px wide or less (X18, X18S ...)
    x20/  wider screens (X20, X20S, X20 Pro ...)
  The voice packs, message tones, logos, missions and saved files stay shared, in this
  folder (/scripts/omnideck/); they are data, not code.

  The screen size comes from system.getVersion() (lcdWidth, as the INAV dashboard reads
  it); without it, the board name (as Yaapu does: "X18" -> x18, anything else -> x20).
]]

local function screenWidth()
  local ok, v = pcall(system.getVersion)
  if ok and type(v) == "table" then
    if type(v.lcdWidth) == "number" and v.lcdWidth > 0 then return v.lcdWidth end
    local b = type(v.board) == "string" and v.board or ""
    if string.find(b, "X18", 1, true) then return 480 end
  end
  return 800
end

-- the folder the chosen copy loads its files from (x18/main.lua and x18/ui.lua prefix it)
OD_DIR = screenWidth() <= 480 and "x18/" or "x20/"
return assert(loadfile(OD_DIR .. "main.lua"))()
