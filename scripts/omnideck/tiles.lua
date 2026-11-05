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

  Loading follows that widget's measurements on an X20S: lcd.loadBitmap()
  costs ~14 ms per tile (decode, not SD I/O), so tiles are loaded from wakeup()
  a couple at a time, centre first, never inside paint(). Evicted bitmaps are
  only freed by the GC, so a full collect runs before the next load after any
  eviction - otherwise old and new bitmaps coexist and Ethos kills the widget.
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
local set = nil            -- active tile set (from scan)
local cache = {}           -- key "z/x/y" -> bitmap, or false when the file is missing
local count = 0
local queue, queued = {}, {}
local needGC = false
local fmtExt = nil         -- extension that worked last; tried first

function TL.setSet(s)
  if s ~= set then TL.clear() end
  set = s
end
function TL.active() return set end

function TL.clear()
  -- nil each entry so the GC sees the dropped references before new loads
  for k in pairs(cache) do cache[k] = nil end
  cache, count, queue, queued, fmtExt = {}, 0, {}, {}, nil
  needGC = true
end

local function tryLoad(path)
  local ok, bmp = pcall(lcd.loadBitmap, path)
  if ok and bmp ~= nil then return bmp end
  return nil
end

local EXTS = { ".jpg", ".bmp", ".png" }
local function loadTile(z, x, y)
  local p, t = set.provider, set.type
  local dp, dt = set.dirP or p, set.dirT or t
  local base
  if p == "ESRI" then base = string.format("%s%s/%s/%d/%d/%d", ROOT, dp, dt, z, y, x)
  else base = string.format("%s%s/%s/%d/%d/%d", ROOT, dp, dt, z, x, y) end
  if fmtExt then
    local b = tryLoad(base .. fmtExt)
    if b then return b end
  end
  for _, e in ipairs(EXTS) do
    if e ~= fmtExt then
      local b = tryLoad(base .. e)
      if b then fmtExt = e return b end
    end
  end
  if p == "GOOGLE" and YAAPU_GOOGLE[t] then
    local yb = string.format("%s%s/%d/%d/s_%d", YAAPU, set.dirY or YAAPU_GOOGLE[t], z, y, x)
    for _, e in ipairs({ ".jpg", ".png" }) do
      local b = tryLoad(yb .. e)
      if b then return b end
    end
  end
  return false
end

-- returns the bitmap, false (no such tile on the card) or nil (not loaded yet)
function TL.get(z, x, y)
  local v = cache[z .. "/" .. x .. "/" .. y]
  if v == nil then
    local k = z .. "/" .. x .. "/" .. y
    if not queued[k] then queued[k] = true queue[#queue + 1] = { z, x, y, k } end
  end
  return v
end

-- called by the map each frame with the visible tile range; drops everything else
-- and re-orders the queue so tiles nearest the aircraft load first
function TL.view(z, x0, y0, x1, y1, cxT, cyT)
  local removed = 0
  for k in pairs(cache) do
    local kz, kx, ky = string.match(k, "^(%d+)/(%-?%d+)/(%-?%d+)$")
    kz, kx, ky = tonumber(kz), tonumber(kx), tonumber(ky)
    if kz ~= z or kx < x0 - 1 or kx > x1 + 1 or ky < y0 - 1 or ky > y1 + 1 then
      cache[k] = nil
      removed = removed + 1
    end
  end
  if removed > 0 then count = count - removed needGC = true end
  local q = {}
  for _, e in ipairs(queue) do
    if e[1] == z and e[2] >= x0 - 1 and e[2] <= x1 + 1 and e[3] >= y0 - 1 and e[3] <= y1 + 1 then q[#q + 1] = e
    else queued[e[4]] = nil end
  end
  table.sort(q, function(a, b)
    return (a[2] - cxT) ^ 2 + (a[3] - cyT) ^ 2 < (b[2] - cxT) ^ 2 + (b[3] - cyT) ^ 2
  end)
  queue = q
end

-- wakeup(): load at most n tiles (2-3 per wakeup measured best on the X20S)
function TL.process(n)
  if set == nil or #queue == 0 then return 0 end
  if needGC then
    collectgarbage()
    collectgarbage()   -- second pass frees userdata with finalisers
    needGC = false
  end
  local done = 0
  while done < (n or 2) and #queue > 0 do
    local e = table.remove(queue, 1)
    queued[e[4]] = nil
    if cache[e[4]] == nil then
      cache[e[4]] = loadTile(e[1], e[2], e[3])
      count = count + 1
      done = done + 1
    end
  end
  return done
end

function TL.pending() return #queue end
function TL.cached() return count end

return TL
