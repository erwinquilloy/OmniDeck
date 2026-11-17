-- OmniDeck Mono Params (SYS > Tools): read and change ArduPlane parameters from the radio.
--   ELRS / Crossfire: ArduPlane Stratos v2.2.1 or later (MAVlite over CRSF).
--   mLRS: Tx Ser Port = cbridge, any ArduPilot (MAVLink through the bridge).
-- S.Port / F.Port are not supported here. A tool of its own because the editor needs more Lua
-- memory than is left beside the OmniDeck telemetry script on a TX12 MK2 (103 KB in use of ~127;
-- 2026-11-17). EdgeTX pauses telemetry scripts while a tool runs, so this one reads the CRSF queue
-- itself: ArduPilot passthrough (armed state, status texts), MAVlite answers (0xF4) and mLRS
-- bridge frames (0xAA). The editor is /SCRIPTS/OMNID/pparam.lua (+ pplist.lua, pmav.lua).
-- Keys: wheel / +- moves, ENTER opens / saves, RTN goes back (from the tab list: leaves).

-- EdgeTX on this radio may run without Lua's table library ("attempt to index a nil value (field
-- 'table')", TX12 MK2, EdgeTX 2.12, 2026-11-13). The few calls OmniDeck makes, in plain Lua, only
-- where the library is missing.
if rawget(_G, "table") == nil then
  local T = {}
  function T.insert(t, a, b)
    if b == nil then t[#t + 1] = a return end
    for i = #t, a, -1 do t[i + 1] = t[i] end
    t[a] = b
  end
  function T.remove(t, pos)
    local n = #t
    if n == 0 then return nil end
    pos = pos or n
    local v = t[pos]
    for i = pos, n - 1 do t[i] = t[i + 1] end
    t[n] = nil
    return v
  end
  function T.concat(t, sep, i, j)
    sep, i, j = sep or "", i or 1, j or #t
    local out = ""
    for k = i, j do out = out .. t[k] .. (k < j and sep or "") end
    return out
  end
  function T.sort(t, lt)
    lt = lt or function(a, b) return a < b end
    for i = 2, #t do
      local v, k = t[i], i - 1
      while k >= 1 and lt(v, t[k]) do t[k + 1] = t[k] k = k - 1 end
      t[k + 1] = v
    end
  end
  local function unpack(t, i, j)
    i, j = i or 1, j or #t
    if i > j then return end
    return t[i], unpack(t, i + 1, j)
  end
  T.unpack = unpack
  table = T
end

local ROOT = "/SCRIPTS/OMNID/"
local page, msg = nil, ""
local s = { fc = nil, link = nil, armed = false, msgs = {} }
local lastRx = -100
local base = getTime()
local function clock() return (getTime() - base) / 100 end

-- the clock and the mLRS bridge queue (newest 12 frames, kept only while the editor asks: E.envOn)
local E = { os = { clock = clock }, envOn = false, envAt = nil }
local envQ = {}
function E.popEnv() return table.remove(envQ, 1) end
function E.envClear() envQ = {} end

local T = { s = s }
function T.alive()
  if s.fc == nil then return nil end
  return clock() - lastRx < 3
end
function T.crsfPush(cmd, data) return crossfireTelemetryPush(cmd, data) end

-- 0x5001 (ArduPilot status): bit 8 = armed, i.e. bit 0 of the value's second byte
local function value(appLo, appHi, v1)
  if appLo == 0x01 and appHi == 0x50 then s.armed = v1 % 2 == 1 end
end

local function drain()
  if not crossfireTelemetryPop then return end
  for _ = 1, 40 do
    local cmd, d = crossfireTelemetryPop()
    if cmd == nil then break end
    if cmd == 0xAA and d then
      s.fc, s.link, lastRx = "ArduPilot", "CRSF", clock()
      E.envAt = clock()
      if E.envOn then
        if #envQ >= 12 then table.remove(envQ, 1) end
        envQ[#envQ + 1] = d
      end
    elseif (cmd == 0x80 or cmd == 0x7F) and d then
      local k = d[1]
      if k == 0xF4 then
        if T.onMavlite then T.onMavlite(d) end
      elseif k == 0xF0 or k == 0xF1 or k == 0xF2 then
        s.fc, s.link, lastRx = "ArduPilot", "CRSF", clock()
        if k == 0xF0 and #d >= 7 then
          value(d[2], d[3], d[5])
        elseif k == 0xF2 then
          for i = 0, math.min((d[2] or 0) - 1, 9) do
            local b = 3 + 6 * i
            if d[b + 5] == nil then break end
            value(d[b], d[b + 1], d[b + 3])
          end
        elseif #d >= 3 then
          -- status text: severity, then the text up to a 0 (the editor looks for
          -- "Param read failed (NAME)", ArduPilot's answer to a name it doesn't have)
          local txt = string.char(table.unpack(d, 3, #d))
          local z = string.find(txt, "\0", 1, true)
          if z then txt = string.sub(txt, 1, z - 1) end
          local m = s.msgs
          if #m >= 5 then table.remove(m, 1) end
          m[#m + 1] = { text = txt, sev = d[2] }
        end
      end
    end
  end
end

local ctx = { T = T, E = E, cfg = { paramFlight = 0 } }

local function init()
  -- Setup's AIR EDITS for this model
  local chunk = loadScript(ROOT .. "cfg.lua", "bt")
  local C = chunk and chunk()
  if C then ctx.cfg = C.read() end
  C, chunk = nil, nil
  collectgarbage()
  local ok, p = false, nil
  chunk, msg = loadScript(ROOT .. "pparam.lua", "bt")
  if chunk then ok, p = pcall(chunk) end
  if ok and p then page = p else msg = "PPARAM: " .. tostring(p or msg) end
  chunk = nil
  collectgarbage()
end

local function run(event)
  drain()
  lcd.clear()
  if not page then
    lcd.drawFilledRectangle(0, 0, 128, 9, FORCE)
    lcd.drawText(1, 1, "OMNIDECK PARAMS", INVERS)
    for i = 0, 4 do lcd.drawText(1, 12 + i * 8, string.sub(msg, i * 25 + 1, i * 25 + 25), SMLSIZE) end
    return (event == EVT_VIRTUAL_EXIT or event == EVT_VIRTUAL_ENTER) and 1 or 0
  end
  -- the editor can't work now (no ArduPilot, no answer): ENTER or RTN leaves
  if not page.wantsEnter(ctx) and (event == EVT_VIRTUAL_EXIT or event == EVT_VIRTUAL_ENTER) then
    page.close(ctx)
    return 1
  end
  page.draw(ctx, event)
  if ctx.wantNext then   -- RTN on the tab list, or long ENTER
    page.close(ctx)
    return 1
  end
  return 0
end

return { init = init, run = run }
