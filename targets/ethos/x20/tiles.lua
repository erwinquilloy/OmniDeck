-- EdgeTX: run in the adapter's environment (etx.lua sets OD_ENV). EdgeTX 2.9 breaks loadScript's
-- env argument (_ENV nil), so the module sets it itself; on Ethos OD_ENV is nil and nothing changes.
local _ENV = OD_ENV or _ENV
--[[
  OmniDeck offline map tiles.

  Reads the same SD-card tile sets as the ETHOS Mapping Widget (b14ckyy, after
  Yaapu), so tiles made with the High Resolution Map Generator
  (https://martinovem.github.io/High-Resolution-Map-Generator/, output target
  "b14ckyy ETHOS Mapping Widget") or existing Yaapu Google tiles just work:

    /bitmaps/ethosmaps/maps/GOOGLE/<Type>/<z>/<x>/<y>.jpg     (also OSM, MAPTILER)
    /bitmaps/ethosmaps/maps/ESRI/<Type>/<z>/<y>/<x>.jpg        (ESRI: y before x)
    /bitmaps/yaapu/maps/Google<Type>Map/<z>/<y>/s_<x>.jpg|png  (Yaapu fallback, Google only)

  Tiles are 100x100 px Web Mercator; formats tried in order jpg, bmp, png.

  Loading (test43) follows that widget's tileloader as it is now:
  - lcd.loadBitmap() returns a handle at once; the file is decoded at its first
    draw. A missing file gives a handle of width 0 that draws nothing - not nil
    and no error (its ETHOS-API-QUIRKS notes). So the tile format is found once
    with io.open; after that tiles load without a check, and each one on screen
    is checked when the loader is idle (width() 0 = missing: the other formats
    and the Yaapu folder are tried, else it stays background).
  - paint() only says which tiles it shows (TL.want) and reads the cache
    (TL.get). wakeup() (TL.process) rebuilds the queue when that window changes
    - visible tiles nearest the centre first, then a ring of one tile - and loads
    until a time budget or a count is used up, instead of 2 per wakeup.
  - Evicted bitmaps are only freed by the GC, so a full collect runs before the
    next load after any eviction - otherwise old and new bitmaps coexist and
    Ethos kills the widget.
]]

local TL = {}

local TILE = 100
TL.TILE = TILE
local ROOT = OD_TILES or "/bitmaps/ethosmaps/maps/"      -- EdgeTX: /IMAGES/ethosmaps/maps/
local YAAPU = OD_YAAPU_TILES or "/bitmaps/yaapu/maps/"   -- EdgeTX: /IMAGES/yaapu/maps/
local PROVIDERS = { "GOOGLE", "ESRI", "OSM", "MAPTILER" }
local TYPES = { "Satellite", "Hybrid", "Map", "Terrain", "Street", "Outdoor", "Topo", "Winter", "OSM Style" }
local YAAPU_GOOGLE = { Satellite = "GoogleSatelliteMap", Hybrid = "GoogleHybridMap", Map = "GoogleMap", Terrain = "GoogleTerrainMap" }

local floor, max, min = math.floor, math.max, math.min

-- ---------------------------------------------------------------- folder scan
local function listDir(path)
  if not (system and system.listFiles) then return {} end
  local ok, entries = pcall(system.listFiles, path)
  if not ok or type(entries) ~= "table" then return {} end
  local out = {}
  for _, n in ipairs(entries) do
    if type(n) == "string" then
      n = string.gsub(n, "/+$", "")
      if n ~= "" and n ~= "." and n ~= ".." then out[#out + 1] = n end
    end
  end
  return out
end

local function zoomsIn(path, zs)
  for _, n in ipairs(listDir(path)) do
    local z = tonumber(n)
    if z and z == floor(z) and z >= 1 and z <= 20 then zs[z] = true end
  end
end

-- folder names in a directory, keyed by their lower-case form: map makers differ in capitals
-- ("GOOGLE/Hybrid", "Google/hybrid"), so folders are matched ignoring case
local function lowerNames(path)
  local m = {}
  for _, n in ipairs(listDir(path)) do m[string.lower(n)] = n end
  return m
end

-- every provider/type with at least one zoom folder:
-- { {label=, provider=, type=, minZ=, maxZ=, dirP=, dirT=, dirY=}, ... } (dir*: names as on the card)
function TL.scan()
  local sets = {}
  local seen = {}
  local provs = lowerNames(ROOT)
  local yaapuDirs = lowerNames(YAAPU)
  for _, p in ipairs(PROVIDERS) do
    local dirP = provs[string.lower(p)]
    local types = dirP and lowerNames(ROOT .. dirP) or {}
    for _, t in ipairs(TYPES) do
      local zs = {}
      local dirT = types[string.lower(t)]
      if dirT then zoomsIn(ROOT .. dirP .. "/" .. dirT, zs) end
      local dirY = p == "GOOGLE" and YAAPU_GOOGLE[t] and yaapuDirs[string.lower(YAAPU_GOOGLE[t])] or nil
      if dirY then zoomsIn(YAAPU .. dirY, zs) end
      local lo, hi
      for z in pairs(zs) do lo = (lo == nil or z < lo) and z or lo; hi = (hi == nil or z > hi) and z or hi end
      if lo and not seen[p .. t] then
        seen[p .. t] = true
        sets[#sets + 1] = { label = p .. " " .. t, provider = p, type = t, minZ = lo, maxZ = hi,
                            dirP = dirP, dirT = dirT, dirY = dirY }
      end
    end
  end
  return sets
end

-- ---------------------------------------------------------------- probe (no folder listing)
-- OpenTX can't list folders, so the tile set is found by looking for the tile under a
-- position: every provider/type (then Yaapu's Google folders) at the usual zooms first,
-- a few files per call. Once one is found, the zooms around it give the set's range.
-- A full pass that finds nothing waits PROBE_IDLE_S before trying again.
function TL.canList() return system ~= nil and system.listFiles ~= nil end

local ZORDER = { 17, 16, 18, 15, 14, 19, 13, 12, 20, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1 }
local PROBE_PER_CALL, PROBE_IDLE_S = 3, 60
local probe = { c = 1, zi = 1, idleUntil = -1, found = nil }
local cands = nil

local function candList()
  local out = {}
  for _, p in ipairs(PROVIDERS) do
    for _, t in ipairs(TYPES) do out[#out + 1] = { p = p, t = t } end
  end
  for _, t in ipairs({ "Satellite", "Hybrid", "Map", "Terrain" }) do out[#out + 1] = { p = "GOOGLE", t = t, y = YAAPU_GOOGLE[t] } end
  return out
end

local function tileThere(c, z, lat, lon)
  local px, py = TL.toPixel(lat, lon, z)
  local x, y = floor(px / TILE), floor(py / TILE)
  local base
  if c.y then base = string.format("%s%s/%d/%d/s_%d", YAAPU, c.y, z, y, x)
  elseif c.p == "ESRI" then base = string.format("%s%s/%s/%d/%d/%d", ROOT, c.p, c.t, z, y, x)
  else base = string.format("%s%s/%s/%d/%d/%d", ROOT, c.p, c.t, z, x, y) end
  local exists = system.fileExists
  return exists(base .. ".jpg") or exists(base .. ".png") or (not c.y and exists(base .. ".bmp"))
end

-- one step of the search; returns the set once found (and every call after)
function TL.probe(lat, lon, now)
  if probe.found then return probe.found end
  if not (system and system.fileExists) or lat == nil then return nil end
  if now < probe.idleUntil then return nil end
  cands = cands or candList()
  for _ = 1, PROBE_PER_CALL do
    local c, z = cands[probe.c], ZORDER[probe.zi]
    if tileThere(c, z, lat, lon) then
      local lo, hi = z, z
      while lo > 1 and tileThere(c, lo - 1, lat, lon) do lo = lo - 1 end
      while hi < 20 and tileThere(c, hi + 1, lat, lon) do hi = hi + 1 end
      local label = c.p .. " " .. c.t
      probe.found = { label = label, provider = c.p, type = c.t, minZ = lo, maxZ = hi,
                      dirP = c.p, dirT = c.t, dirY = c.y }
      return probe.found
    end
    probe.zi = probe.zi + 1
    if probe.zi > #ZORDER then
      probe.zi, probe.c = 1, probe.c + 1
      if probe.c > #cands then probe.c, probe.idleUntil = 1, now + PROBE_IDLE_S return nil end
    end
  end
  return nil
end

-- ---------------------------------------------------------------- projection
-- absolute Web Mercator pixel of a position at zoom z (world = 2^z * 100 px)
function TL.toPixel(lat, lon, z)
  lat = max(-85.05112878, min(85.05112878, lat))
  local size = (2 ^ z) * TILE
  local sl = math.sin(math.rad(lat))
  local x = (lon + 180) / 360 * size
  local y = (0.5 - math.log((1 + sl) / (1 - sl)) / (4 * math.pi)) * size
  return x, y
end

-- metres per pixel at latitude lat, zoom z
function TL.mpp(lat, z)
  return 40075017 * math.cos(math.rad(lat)) / ((2 ^ z) * TILE)
end

-- ---------------------------------------------------------------- cache + queue
-- One zoom is held at a time: cache[x][y] = bitmap, or false when there is no such tile. Numbers,
-- not "z/x/y" strings: building a key per tile cost more Lua than anything else here.
local set = nil            -- active tile set (from scan)
local cz = nil             -- the zoom the cache holds
local cache = {}
local count = 0
local qx, qy, qHead, qN = {}, {}, 1, 0   -- the load queue (tile x, y at zoom cz)
local needGC = false
local fmt = nil            -- { ext = ".jpg", yaapu = bool }: the format found on the card
local UK = 2097152         -- unverified key = x * UK + y (2^21 > tiles across at zoom 20)
local unverified, unverN = {}, 0   -- loaded without a check, not yet looked at
local want = { z = nil }   -- the window paint() shows: z, x0, y0, x1, y1, cx, cy
local built = {}           -- the window the queue was built for
local verifyAt = -1
local VERIFY_S = 0.3       -- an idle loader checks one tile on screen this often
local BUDGET_S, MAX_PER_CALL = 0.025, 10

function TL.setSet(s)
  if s ~= set then TL.clear() end
  set = s
end
function TL.active() return set end

function TL.clear()
  -- nil each entry so the GC sees the dropped references before new loads
  for x, col in pairs(cache) do
    for y in pairs(col) do col[y] = nil end
    cache[x] = nil
  end
  cache, cz, count, fmt = {}, nil, 0, nil
  qHead, qN = 1, 0
  unverified, unverN = {}, 0
  built = {}
  needGC = true
end

local function tryLoad(path)
  local ok, bmp = pcall(lcd.loadBitmap, path)
  if ok and bmp ~= nil then return bmp end
  return nil
end

local function exists(path)
  local ok, f = pcall(io.open, path, "r")
  if ok and f then f:close() return true end
  return false
end

local function basePath(z, x, y)
  local p = set.provider
  local dp, dt = set.dirP or p, set.dirT or set.type
  if p == "ESRI" then return string.format("%s%s/%s/%d/%d/%d", ROOT, dp, dt, z, y, x) end
  return string.format("%s%s/%s/%d/%d/%d", ROOT, dp, dt, z, x, y)
end
local function yaapuPath(z, x, y)
  return string.format("%s%s/%d/%d/s_%d", YAAPU, set.dirY or YAAPU_GOOGLE[set.type], z, y, x)
end

-- every candidate looked for on the card (jpg, bmp, png, then Yaapu's Google folder); the
-- first one there is loaded, and the first format found is used for the fast path after
local EXTS, YEXTS = { ".jpg", ".bmp", ".png" }, { ".jpg", ".png" }
local function probeLoad(z, x, y)
  local base = basePath(z, x, y)
  for _, e in ipairs(EXTS) do
    if exists(base .. e) then
      local b = tryLoad(base .. e)
      if b then fmt = fmt or { ext = e } return b end
    end
  end
  if set.provider == "GOOGLE" and YAAPU_GOOGLE[set.type] then
    local yb = yaapuPath(z, x, y)
    for _, e in ipairs(YEXTS) do
      if exists(yb .. e) then
        local b = tryLoad(yb .. e)
        if b then fmt = fmt or { ext = e, yaapu = true } return b end
      end
    end
  end
  return false
end

local function loadTile(z, x, y)
  if fmt then   -- fast path: no file check (checked later, when on screen)
    local b = tryLoad((fmt.yaapu and yaapuPath(z, x, y) or basePath(z, x, y)) .. fmt.ext)
    if b then
      local uk = x * UK + y
      if not unverified[uk] then unverified[uk] = true unverN = unverN + 1 end
      return b
    end
  end
  return probeLoad(z, x, y)
end

-- returns the bitmap, false (no such tile on the card) or nil (not loaded yet). Cache only:
-- paint() never touches the card or the queue.
function TL.get(z, x, y)
  if z ~= cz then return nil end
  local col = cache[x]
  if col then return col[y] end
  return nil
end

-- paint(): the tile window on screen and the centre tile. Only stored; wakeup acts on it.
function TL.want(z, x0, y0, x1, y1, cx, cy)
  local w = want
  w.z, w.x0, w.y0, w.x1, w.y1, w.cx, w.cy = z, x0, y0, x1, y1, cx, cy
end

-- drop what left the window (plus its ring of one tile), or everything at another zoom; queue
-- the window again: the visible tiles in square rings outward from the centre tile, then the
-- ring. Cached ones are skipped when their turn comes.
local function rebuild()
  local w = want
  built.z, built.x0, built.y0, built.x1, built.y1 = w.z, w.x0, w.y0, w.x1, w.y1
  local z, vx0, vy0, vx1, vy1, cx, cy = w.z, w.x0, w.y0, w.x1, w.y1, w.cx, w.cy
  local x0, y0, x1, y1 = vx0 - 1, vy0 - 1, vx1 + 1, vy1 + 1
  local removed = 0
  for x, col in pairs(cache) do
    local all = z ~= cz or x < x0 or x > x1
    for y in pairs(col) do
      if all or y < y0 or y > y1 then
        col[y] = nil
        removed = removed + 1
        local uk = x * UK + y
        if unverified[uk] then unverified[uk] = nil unverN = unverN - 1 end
      end
    end
    if all then cache[x] = nil end
  end
  cz = z
  if removed > 0 then count = count - removed needGC = true end
  local n = 1
  cx, cy = max(vx0, min(vx1, cx)), max(vy0, min(vy1, cy))
  qx[1], qy[1] = cx, cy
  local R = max(cx - vx0, vx1 - cx, cy - vy0, vy1 - cy)
  for r = 1, R do
    local ya, yb, xa, xb = cy - r, cy + r, cx - r, cx + r
    for tx = max(vx0, xa), min(vx1, xb) do
      if ya >= vy0 then n = n + 1 qx[n], qy[n] = tx, ya end
      if yb <= vy1 then n = n + 1 qx[n], qy[n] = tx, yb end
    end
    for ty = max(vy0, ya + 1), min(vy1, yb - 1) do
      if xa >= vx0 then n = n + 1 qx[n], qy[n] = xa, ty end
      if xb <= vx1 then n = n + 1 qx[n], qy[n] = xb, ty end
    end
  end
  for tx = x0, x1 do
    n = n + 1 qx[n], qy[n] = tx, y0
    n = n + 1 qx[n], qy[n] = tx, y1
  end
  for ty = vy0, vy1 do
    n = n + 1 qx[n], qy[n] = x0, ty
    n = n + 1 qx[n], qy[n] = x1, ty
  end
  for i = n + 1, #qx do qx[i], qy[i] = nil, nil end
  qHead, qN = 1, n
end

-- idle: one loaded-unchecked tile on screen gets its check. It has been drawn, so width() costs
-- nothing more; 0 means the fast path found no file - look again in every format.
local function verifyOne(now)
  if unverN == 0 or now - verifyAt < VERIFY_S then return end
  verifyAt = now
  local w = want
  for uk in pairs(unverified) do
    local x = math.floor(uk / UK)
    local y = uk - x * UK
    if x >= w.x0 and x <= w.x1 and y >= w.y0 and y <= w.y1 then
      unverified[uk] = nil
      unverN = unverN - 1
      local col = cache[x]
      local b = col and col[y]
      if b then
        local ok, wd = pcall(function() return b:width() end)
        if ok and wd == 0 then col[y] = probeLoad(cz, x, y) end
      end
      return
    end
  end
end

-- wakeup(): rebuild the queue if the window moved, then load until BUDGET_S seconds or
-- MAX_PER_CALL tiles are used (a load is a handle, well under a millisecond on Ethos; the decode
-- comes at the tile's first draw). Idle: check a tile on screen.
function TL.process(budget, maxN)
  local w = want
  if set == nil or w.z == nil then return 0 end
  if w.z ~= built.z or w.x0 ~= built.x0 or w.y0 ~= built.y0 or w.x1 ~= built.x1 or w.y1 ~= built.y1 then
    rebuild()
  end
  local now = os.clock()
  if qHead > qN then verifyOne(now) return 0 end
  if needGC then
    collectgarbage()
    collectgarbage()   -- second pass frees userdata with finalisers
    needGC = false
  end
  budget, maxN = budget or BUDGET_S, maxN or MAX_PER_CALL
  local done = 0
  while qHead <= qN and done < maxN do
    local tx, ty = qx[qHead], qy[qHead]
    qHead = qHead + 1
    local col = cache[tx]
    if col == nil then col = {} cache[tx] = col end
    if col[ty] == nil then
      col[ty] = loadTile(cz, tx, ty)
      count = count + 1
      done = done + 1
      if os.clock() - now >= budget then break end
    end
  end
  if qHead > qN then qHead, qN = 1, 0 end
  return done
end

function TL.pending() return qN - qHead + 1 end
function TL.cached() return count end
function TL.unverified() return unverN end

return TL
