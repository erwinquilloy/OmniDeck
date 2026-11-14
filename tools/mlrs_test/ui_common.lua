-- shared screen logic (after the core): request AIRSPEED_CRUISE, show what comes back
local NAME = "AIRSPEED_CRUISE"
local st = { sent = 0, last = nil, lastAt = nil, t0 = nil, b0 = 0, rate = 0, nextReq = 0 }
M.onParam = function(n, v) st.last, st.lastAt = n .. " = " .. string.format("%.3f", v), now() end

local function request(push)
  for _, e in ipairs(M.envelopes(M.paramRequest(NAME))) do push(e) end
  st.sent = st.sent + 1
end

local function tick(push, pop)
  local t = now()
  st.t0 = st.t0 or t
  for _ = 1, 40 do
    local data = pop()
    if not data then break end
    M.feed(data, 1)
  end
  if t - st.t0 >= 2 then
    st.rate = (M.stats.bytes - st.b0) / (t - st.t0)
    st.t0, st.b0 = t, M.stats.bytes
  end
  -- ask every 3 s once the autopilot is known (or after 6 s anyway)
  if t >= st.nextReq and (M.target or t > 6) then
    request(push)
    st.nextReq = t + 3
  end
end

local function lines()
  local s = M.stats
  local ids = {}
  for id, n in pairs(s.byId) do ids[#ids + 1] = { id, n } end
  table.sort(ids, function(a, b) return a[2] > b[2] end)
  local top = {}
  for i = 1, math.min(6, #ids) do top[#top + 1] = ids[i][1] .. ":" .. ids[i][2] end
  return {
    "mLRS cbridge test (Tx Ser Port2 = cbridge)",
    string.format("frames %d  bytes %d  %.0f B/s", s.frames, s.bytes, st.rate),
    string.format("MAVLink packets %d  crc bad %d", s.packets, s.bad),
    "autopilot " .. (M.target and (M.target .. "/" .. M.targetComp) or "-- (no HEARTBEAT yet)"),
    "msg ids " .. table.concat(top, " "),
    "requests sent " .. st.sent .. " (" .. NAME .. ")",
    "reply: " .. (st.last and (st.last .. string.format("  (%.0f s ago)", now() - st.lastAt)) or "none yet"),
  }
end
