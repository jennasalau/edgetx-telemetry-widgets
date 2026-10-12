-- BFDash LR: long-range Betaflight telemetry dashboard for EdgeTX colour radios
-- Install to the SD card as: /WIDGETS/BFDash/main.lua
-- Expects CRSF / ExpressLRS sensors: RxBt, Capa, RQly, 1RSS, 2RSS, TPWR, FM,
-- GPS, Sats, Alt, GSpd, Hdg  (run "Discover new sensors" first)

local name     = "BFDash"
local MIN_SATS = 6                                -- sats needed to set home / count distance
local LOG_FILE = "/WIDGETS/BFDash/lastpos.txt"    -- last known positions get appended here

-- Bands setting: which antenna reading (1RSS / 2RSS) belongs to which band
--   0 = Gemini Xrossband, swapped (2.4GHz on 1RSS, 900MHz on 2RSS)
--   1 = Gemini Xrossband (900MHz on 1RSS, 2.4GHz on 2RSS) - the ExpressLRS default
--   2 = 2.4GHz only (single or diversity receiver: best of the two antennas)
--   3 = 900MHz only
local function bestOf(a, b)
  if a < 0 and b < 0 then return math.max(a, b) end
  if a < 0 then return a end
  return b
end

local function splitBands(mode, r1, r2)   -- returns r24, r900 (nil = that band isn't used)
  if mode == 0 then return r1, r2 end
  if mode == 2 then return bestOf(r1, r2), nil end
  if mode == 3 then return nil, bestOf(r1, r2) end
  return r2, r1
end
local BIG_TEXT = true               -- false = every value one font size smaller
local DBM_LO, DBM_HI = -120, -30   -- range covered by the signal bars
local DBM_OK, DBM_LOW = -90, -102  -- green above DBM_OK, amber down to DBM_LOW, red below

local options = {
  { "Cells",   VALUE, 0,  0, 12 },   -- 0 = auto-detect from pack voltage
  { "MinCell", VALUE, 35, 30, 40 },  -- low-cell warning in tenths of a volt (35 = 3.5V)
  { "CapX100", VALUE, 0,  0, 200 },  -- pack capacity in 100s of mAh (18 = 1800mAh), 0 = off
  { "Alerts",  BOOL,  1 },           -- low cell + low range audio/haptic alerts
  { "Bands",   VALUE, 1,  0, 3 },    -- 0 Gemini swapped, 1 Gemini X (900 = 1RSS), 2 = 2.4 only, 3 = 900 only
}

local C = {
  bg     = lcd.RGB(16, 18, 24),
  panel  = lcd.RGB(32, 36, 46),
  off    = lcd.RGB(58, 64, 78),
  text   = lcd.RGB(236, 239, 244),
  dim    = lcd.RGB(140, 148, 162),
  good   = lcd.RGB(40, 200, 100),
  warn   = lcd.RGB(255, 176, 0),
  bad    = lcd.RGB(232, 52, 52),
  accent = lcd.RGB(0, 190, 255),
  span   = lcd.RGB(92, 102, 124),
}

local floor, rad, sin, cos = math.floor, math.rad, math.sin, math.cos
local atan2 = math.atan2 or math.atan

---------------------------------------------------------------- helpers
local function num(sensor)
  local v = getValue(sensor)
  if type(v) == "number" then return v end
  return 0
end

-- EdgeTX can keep showing a sensor's last value after telemetry is lost, so also check
-- getRSSI(), which EdgeTX resets to 0 when the telemetry stream times out.
local function telemetryUp()
  if type(getRSSI) ~= "function" then return true end
  local r = getRSSI()
  return r == nil or r > 0
end

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end

local function box(x, y, w, h, color)
  lcd.drawFilledRectangle(floor(x), floor(y), floor(w), floor(h), color)
end

-- filled rectangle with small rounded corners, built from 1px rows so it
-- only needs lcd.drawFilledRectangle (works on every EdgeTX colour radio)
local RADIUS = 5
local function rbox(x, y, w, h, color, r)
  x, y, w, h = floor(x), floor(y), floor(w), floor(h)
  r = math.min(r or RADIUS, floor(w / 2), floor(h / 2))
  if r < 1 then
    if w > 0 and h > 0 then lcd.drawFilledRectangle(x, y, w, h, color) end
    return
  end
  lcd.drawFilledRectangle(x, y + r, w, h - 2 * r, color)
  for i = 0, r - 1 do
    local dy = r - i - 0.5
    local inset = floor(r - math.sqrt(r * r - dy * dy) + 0.5)
    lcd.drawFilledRectangle(x + inset, y + i, w - 2 * inset, 1, color)
    lcd.drawFilledRectangle(x + inset, y + h - 1 - i, w - 2 * inset, 1, color)
  end
end

local function text(x, y, s, flags)
  lcd.drawText(floor(x), floor(y), s, flags)
end

local function line(x1, y1, x2, y2, color)
  lcd.drawLine(floor(x1), floor(y1), floor(x2), floor(y2), SOLID, color)
end

local function mmss(s)
  local neg = s < 0
  s = math.abs(s)
  return string.format("%s%02d:%02d", neg and "-" or "", floor(s / 60), s % 60)
end

local function fmtDist(m)
  if m < 1000 then return floor(m + 0.5) .. "m"
  elseif m < 10000 then return string.format("%.2fkm", m / 1000) end
  return string.format("%.1fkm", m / 1000)
end

local function cellColor(cell, thr, conn)
  if not conn or cell <= 0 then return C.dim end
  if cell < thr then return C.bad end
  if cell < thr + 0.2 then return C.warn end
  return C.good
end

local function rqColor(rq)
  if rq >= 80 then return C.good elseif rq >= 50 then return C.warn end
  return C.bad
end

local function dbmColor(v)
  if v >= DBM_OK then return C.good elseif v >= DBM_LOW then return C.warn end
  return C.bad
end

-- remember the weakest and strongest reading (0 means "no reading", so skip it)
local function trackRSS(st, v)
  if v and v < 0 then
    st.min = math.min(st.min or v, v)
    st.max = math.max(st.max or v, v)
  end
end

local function satColor(s)
  if s >= 8 then return C.good elseif s >= MIN_SATS then return C.warn end
  return C.bad
end

---------------------------------------------------------------- geo maths
local function dist(lat1, lon1, lat2, lon2)            -- metres (haversine)
  local dlat, dlon = rad(lat2 - lat1), rad(lon2 - lon1)
  local a = sin(dlat / 2) ^ 2 + cos(rad(lat1)) * cos(rad(lat2)) * sin(dlon / 2) ^ 2
  return 2 * 6371000 * math.asin(math.sqrt(a))
end

local function bearing(lat1, lon1, lat2, lon2)         -- degrees, 0 = north
  local y = sin(rad(lon2 - lon1)) * cos(rad(lat2))
  local x = cos(rad(lat1)) * sin(rad(lat2)) - sin(rad(lat1)) * cos(rad(lat2)) * cos(rad(lon2 - lon1))
  return (math.deg(atan2(y, x)) + 360) % 360
end

local function savePos(p)
  local f = io.open(LOG_FILE, "a")
  if not f then return end
  local d = getDateTime()
  io.write(f, string.format("%04d-%02d-%02d %02d:%02d:%02d  %.6f, %.6f\n",
    d.year, d.mon, d.day, d.hour, d.min, d.sec, p.lat, p.lon))
  io.close(f)
end

---------------------------------------------------------------- telemetry
local function resetFlight(wd)
  wd.cells, wd.minRQ = 0, nil
  wd.rs = { b24 = {}, b900 = {} }
  wd.home, wd.prev = nil, nil
  wd.flown, wd.maxDist = 0, 0
end

local function tick(wd)
  local t = wd.t
  t.cell, t.dist, t.rel, t.range, t.eff, t.capLeft = 0, nil, nil, nil, nil, nil
  t.lat, t.lon = nil, nil
  t.rq   = num("RQly")
  t.conn = t.rq > 0 and telemetryUp()
  t.v    = num("RxBt")
  t.mah  = num("Capa")
  local r1, r2 = num("1RSS"), num("2RSS")
  t.r24, t.r900 = splitBands(wd.options.Bands, r1, r2)
  t.pwr  = num("TPWR")
  t.sats = num("Sats")
  t.alt  = num("Alt")
  t.spd  = num("GSpd")
  t.hdg  = num("Hdg")

  -- Betaflight appends "*" to the flight mode when disarmed
  local fm = getValue("FM")
  if type(fm) ~= "string" or fm == "" then fm = "----" end
  local armed = t.conn and string.sub(fm, -1) ~= "*"
  t.armed = armed
  t.fm = (string.gsub(fm, "%*", ""))

  local g = getValue("GPS")
  local hasPos = t.conn and type(g) == "table" and g.lat ~= nil and g.lon ~= nil
                 and (g.lat ~= 0 or g.lon ~= 0)
  local fix = hasPos and t.sats >= MIN_SATS

  -- connection edges: new link = new pack, lost link = save last position
  if t.conn and not wd.wasConn then resetFlight(wd) end
  if wd.wasConn and not t.conn and wd.lastPos then savePos(wd.lastPos) end
  wd.wasConn = t.conn
  if not t.conn then
    wd.armedPrev = false
    return
  end

  if hasPos then
    t.lat, t.lon = g.lat, g.lon
    wd.lastPos = { lat = g.lat, lon = g.lon }
  end

  -- home: set on arming (same as Betaflight), or on first good fix if armed without one
  if armed and fix and (not wd.armedPrev or not wd.home) then
    wd.home = { lat = g.lat, lon = g.lon }
  end
  wd.armedPrev = armed

  if wd.home and hasPos then
    t.dist = dist(g.lat, g.lon, wd.home.lat, wd.home.lon)
    wd.maxDist = math.max(wd.maxDist, t.dist)
    -- direction home relative to the quad's direction of travel
    t.rel = (bearing(g.lat, g.lon, wd.home.lat, wd.home.lon) - t.hdg + 360) % 360
  end

  -- distance flown: only while armed with a good fix, ignore jitter and glitches
  if armed and fix then
    if wd.prev then
      local d = dist(wd.prev.lat, wd.prev.lon, g.lat, g.lon)
      if d >= 3 then
        if d < 500 then wd.flown = wd.flown + d end
        wd.prev = { lat = g.lat, lon = g.lon }
      end
    else
      wd.prev = { lat = g.lat, lon = g.lon }
    end
  elseif not armed then
    wd.prev = nil
  end

  -- battery
  if wd.options.Cells > 0 then
    wd.cells = wd.options.Cells
  elseif wd.cells == 0 and t.v > 2 then
    wd.cells = math.ceil(t.v / 4.35)
  end
  if wd.cells > 0 then t.cell = t.v / wd.cells end
  wd.minRQ = math.min(wd.minRQ or t.rq, t.rq)
  trackRSS(wd.rs.b24, t.r24)
  trackRSS(wd.rs.b900, t.r900)

  -- efficiency and estimated range (keeps a 20% capacity reserve)
  if wd.flown > 300 then t.eff = t.mah / (wd.flown / 1000) end
  local cap = wd.options.CapX100 * 100
  if cap > 0 then
    t.capLeft = clamp(1 - t.mah / cap, 0, 1)
    if t.eff and t.eff > 0 then
      t.range = math.max(0, cap * 0.8 - t.mah) / t.eff * 1000
    end
  end

  -- alerts
  if wd.options.Alerts == 1 and armed then
    local now = getTime()
    local thr = wd.options.MinCell / 10
    if t.cell > 0 and t.cell < thr and now - wd.lastWarn > 1000 then
      playTone(1600, 250, 100, PLAY_NOW)
      playHaptic(40, 0)
      wd.lastWarn = now
    end
    if t.range and t.dist and t.dist > 200 and t.range < t.dist * 1.2
       and now - wd.lastRangeWarn > 1500 then
      playTone(700, 400, 150, PLAY_NOW)
      playTone(700, 400, 0)
      playHaptic(60, 100)
      wd.lastRangeWarn = now
    end
  end
end

---------------------------------------------------------------- drawing
local FONTS = { XXLSIZE, DBLSIZE, MIDSIZE, 0, SMLSIZE }

-- Draw s inside the box (x, y, w, h) with the biggest font that fits,
-- starting from maxFont. Measures real text size, so it adapts to any screen.
-- If tmpl is given, the font is chosen to fit tmpl instead of s, so the size
-- stays steady as the value changes (e.g. "850m" -> "1.20km").
local function fitText(x, y, w, h, s, color, align, maxFont, tmpl)
  local started = (maxFont == nil)
  local font = SMLSIZE
  for _, f in ipairs(FONTS) do
    if f == maxFont then started = true end
    if started then
      font = f
      local fw, fhh = lcd.sizeText(tmpl or s, f)
      if fw <= w and fhh <= h then break end
    end
  end
  local tw, th = lcd.sizeText(s, font)
  local tx = x
  if align == "center" then tx = x + (w - tw) / 2
  elseif align == "right" then tx = x + w - tw end
  lcd.drawText(floor(tx), floor(y + (h - th) / 2), s, font + color)
end

local function bars(x, y, w, h, pct, color)
  local n, gap = 5, 3
  local bw = (w - gap * (n - 1)) / n
  local lit = math.ceil(pct / 20)
  for i = 1, n do
    local bh = h * i / n
    rbox(x + (i - 1) * (bw + gap), y + h - bh, bw, bh, i <= lit and color or C.off, 2)
  end
end

-- signal range bar: grey track, lighter span from weakest to strongest reading,
-- coloured marker for the current reading
local function rangeBar(x, y, w, h, v, st, conn)
  local function px(d) return x + w * clamp((d - DBM_LO) / (DBM_HI - DBM_LO), 0, 1) end
  rbox(x, y, w, h, C.off, 2)
  if st.min then
    local a, b = px(st.min), px(st.max)
    rbox(a, y, math.max(3, b - a), h, C.span, 2)
  end
  if conn and v and v < 0 then
    box(px(v) - 2, y - 3, 4, h + 6, dbmColor(v))
  end
end

-- solid arrow pointing toward home; 0 deg = straight ahead (top of screen)
-- filled by fanning lines from the tip, so it only needs lcd.drawLine
local function arrow(cx, cy, r, deg, color)
  local function pt(a, rr)
    local ang = rad(deg + a)
    return cx + rr * sin(ang), cy - rr * cos(ang)
  end
  local tx, ty = pt(0, r)
  local lx, ly = pt(140, r)
  local rx, ry = pt(-140, r)
  local nx, ny = pt(180, r * 0.30)
  local steps = math.max(8, floor(r * 1.5))
  for i = 0, steps do
    local f = i / steps
    line(tx, ty, lx + (nx - lx) * f, ly + (ny - ly) * f, color)
    line(tx, ty, rx + (nx - rx) * f, ry + (ny - ry) * f, color)
  end
end

local function drawFull(wd)
  local z, t = wd.zone, wd.t
  local x, y, w, h = z.x, z.y, z.w, z.h
  local p, inner = 6, 8
  local conn = t.conn
  local thr = wd.options.MinCell / 10
  local _, lh = lcd.sizeText("A", SMLSIZE)

  -- font caps; BIG_TEXT = false drops every value one size
  local bigOn = BIG_TEXT
  local F_HUGE = bigOn and XXLSIZE or DBLSIZE
  local F_BIG  = bigOn and DBLSIZE or MIDSIZE
  local F_MID  = bigOn and MIDSIZE or 0

  box(x, y, w, h, C.bg)

  -- top bar: flight mode | timer | arm state
  local topH = floor(h * 0.15)
  rbox(x, y, w, topH, C.panel)
  local fmText, fmCol = t.fm, C.text
  if not conn then fmText, fmCol = "NO TELEMETRY", C.bad
  elseif t.fm == "!FS!" then fmCol = C.bad
  elseif t.fm == "RTH" then fmCol = C.warn
  elseif t.fm == "!ERR" or t.fm == "WAIT" then fmCol = C.warn end
  fitText(x + inner, y + 3, w * 0.36, topH - 6, fmText, fmCol, "left", F_BIG)

  local tm = model.getTimer(0)
  fitText(x + w * 0.40, y + 3, w * 0.20, topH - 6, mmss(tm and tm.value or 0), C.text, "center", F_MID)

  local pw = floor(w * 0.24)
  local px = x + w - pw - p
  local pillCol = not conn and C.off or (t.armed and C.bad or C.good)
  local pillTxt = not conn and "NO LINK" or (t.armed and "ARMED" or "DISARMED")
  rbox(px, y + p, pw, topH - p * 2, pillCol, 4)
  fitText(px + 4, y + p, pw - 8, topH - p * 2, pillTxt, C.text, "center", F_MID)

  -- middle row geometry
  local midY   = y + topH + p
  local midH   = floor(h * 0.42)
  local hw     = floor((w - 2 * p) * 0.37)
  local cw     = floor((w - 2 * p) * 0.28)
  local labelH = lh + 6
  local lineH  = math.max(lh + 4, floor(midH * 0.24))
  local valY   = midY + labelH
  local valH   = midH - labelH - lineH - 4
  local lineY  = midY + midH - lineH - 2

  -- home panel
  local hx = x
  rbox(hx, midY, hw, midH, C.panel)
  text(hx + inner, midY + 4, wd.home and "HOME" or "HOME NOT SET", SMLSIZE + (wd.home and C.dim or C.warn))
  local r  = math.max(6, math.min(valH / 2 - 2, hw * 0.10))
  local cx = hx + hw - inner - r
  local cy = valY + valH / 2
  fitText(hx + inner, valY, hw - inner * 2 - r * 2 - 10, valH,
    t.dist and fmtDist(t.dist) or "---", C.text, "left", F_HUGE, "8.88km")
  lcd.drawCircle(floor(cx), floor(cy), floor(r + 2), C.off)
  if t.rel then
    -- heading comes from GPS course, so it's only meaningful while moving
    arrow(cx, cy, r - 2, t.rel, t.spd >= 5 and C.accent or C.dim)
  end
  if t.range then
    local rc = C.good
    if t.dist and t.range < t.dist * 1.2 then rc = C.bad
    elseif t.dist and t.range < t.dist * 2 then rc = C.warn end
    fitText(hx + inner, lineY, hw - inner * 2, lineH, "RANGE " .. fmtDist(t.range), rc, "left", F_MID)
    fitText(hx + hw / 2, midY + 2, hw / 2 - inner, lh + 2, "max " .. fmtDist(wd.maxDist), C.dim, "right", SMLSIZE)
  else
    fitText(hx + inner, lineY, hw - inner * 2, lineH, "MAX " .. fmtDist(wd.maxDist), C.dim, "left", F_MID)
  end

  -- cell average panel
  local bx = hx + hw + p
  local vCol = cellColor(t.cell, thr, conn)
  rbox(bx, midY, cw, midH, C.panel)
  text(bx + inner, midY + 4, "CELL AVG " .. (wd.cells > 0 and (wd.cells .. "S") or "?S"), SMLSIZE + C.dim)
  local barH = math.max(5, floor(midH * 0.06))
  fitText(bx + inner, valY, cw - inner * 2, valH - barH - 4,
    conn and string.format("%.2fV", t.cell) or "-.--V", vCol, "left", F_HUGE, "8.88V")

  local barY = valY + valH - barH
  local barW = cw - inner * 2
  local frac, barCol
  if t.capLeft then                      -- capacity-based fuel gauge if capacity is set
    frac = t.capLeft
    barCol = frac < 0.2 and C.bad or (frac < 0.35 and C.warn or C.good)
  else                                   -- otherwise voltage-based
    frac = clamp((t.cell - 3.3) / (4.2 - 3.3), 0, 1)
    barCol = vCol
  end
  rbox(bx + inner, barY, barW, barH, C.off, 2)
  if conn and frac > 0 then rbox(bx + inner, barY, barW * frac, barH, barCol, 2) end
  fitText(bx + inner, lineY, cw - inner * 2, lineH, conn and (floor(t.mah) .. "mAh") or "--mAh", C.text, "left", F_MID)

  -- link panel: LQ on top, then one row per band (current dBm, weakest/strongest, range bar)
  local lx = bx + cw + p
  local lw = x + w - lx
  local inW = lw - inner * 2
  local rqCol = conn and rqColor(t.rq) or C.dim
  rbox(lx, midY, lw, midH, C.panel)
  text(lx + inner, midY + 4, "LINK", SMLSIZE + C.dim)
  if conn then
    fitText(lx + lw / 2, midY + 2, lw / 2 - inner, lh + 2, floor(t.pwr) .. "mW", C.dim, "right", SMLSIZE)
  end

  local top   = midY + labelH
  local avail = midH - labelH - 4
  local lqH   = floor(avail * 0.40)
  local bandH = floor((avail - lqH) / 2)
  local sideW = floor(inW * 0.30)
  fitText(lx + inner, top, inW - sideW - 6, lqH,
    conn and (floor(t.rq) .. "%") or "--%", rqCol, "left", F_HUGE, "100%")
  bars(lx + lw - inner - sideW, top + 2, sideW, lqH - lh - 8, conn and t.rq or 0, rqCol)
  if wd.minRQ then
    fitText(lx + lw - inner - sideW, top + lqH - lh - 4, sideW, lh + 2,
      "min " .. floor(wd.minRQ) .. "%", C.dim, "right", SMLSIZE)
  end

  local bands = {
    { "2.4G", t.r24,  wd.rs.b24 },
    { "900M", t.r900, wd.rs.b900 },
  }
  local tagW, curW = floor(inW * 0.21), floor(inW * 0.34)
  for i, b in ipairs(bands) do
    local by   = top + lqH + (i - 1) * bandH
    local bH   = math.max(4, floor(bandH * 0.15))
    local txtH = bandH - bH - 8
    local unused = b[2] == nil                -- band switched off in the Bands setting
    local has  = conn and not unused and b[2] < 0
    fitText(lx + inner, by, tagW, txtH, b[1], C.dim, "left", 0)
    fitText(lx + inner + tagW, by, curW, txtH, unused and "off" or (has and tostring(floor(b[2])) or "--"),
      has and C.text or C.dim, "left", F_MID, "-188")
    local mm = unused and "" or (b[3].min and (floor(b[3].min) .. "/" .. floor(b[3].max)) or "--/--")
    fitText(lx + inner + tagW + curW, by, inW - tagW - curW, txtH, mm, C.dim, "right", SMLSIZE, "-188/-188")
    rangeBar(lx + inner, by + txtH + 3, inW, bH, b[2], b[3], conn)
  end

  -- tiles row
  local botY = midY + midH + p
  local botH = floor(h * 0.24)
  local tw = (w - p * 4) / 5
  local tiles = {
    { "SATS",       conn and tostring(floor(t.sats)) or "--", conn and satColor(t.sats) or C.dim, "88" },
    { "ALT m",      conn and tostring(floor(t.alt + 0.5)) or "--", C.text, "8888" },
    { "SPEED km/h", conn and tostring(floor(t.spd + 0.5)) or "--", C.text, "888" },
    { "FLOWN",      fmtDist(wd.flown), C.text, "88.8km" },
    { "mAh/km",     t.eff and tostring(floor(t.eff + 0.5)) or "--", C.text, "8888" },
  }
  for i, tl in ipairs(tiles) do
    local tx = x + (i - 1) * (tw + p)
    rbox(tx, botY, tw, botH, C.panel)
    fitText(tx + 6, botY + 3, tw - 12, lh + 2, tl[1], C.dim, "left", SMLSIZE)
    fitText(tx + 6, botY + labelH, tw - 12, botH - labelH - 4, tl[2], tl[3], "center", F_BIG, tl[4])
  end

  -- GPS position strip
  local sy = botY + botH + p
  local sh = y + h - sy
  if sh >= lh then
    local s, col
    if conn and t.lat then
      s, col = string.format("GPS  %.6f, %.6f", t.lat, t.lon), C.text
    elseif conn then
      s, col = "GPS  waiting for fix (" .. floor(t.sats) .. " sats)", C.warn
    elseif wd.lastPos then
      s, col = string.format("LAST POS  %.6f, %.6f  (saved to SD)", wd.lastPos.lat, wd.lastPos.lon), C.warn
    else
      s, col = "GPS  --", C.dim
    end
    rbox(x, sy, w, sh, C.panel)
    fitText(x + inner, sy, w - inner * 2, sh, s, col, "left", F_MID)
  end
end

-- small zones: the long-range essentials
local function drawCompact(wd)
  local z, t = wd.zone, wd.t
  local x, y, w, h = z.x, z.y, z.w, z.h
  local hh = h / 2
  rbox(x, y, w, h, C.panel)
  if not t.conn then
    if wd.lastPos then
      fitText(x + 4, y, w - 8, hh, "LOST - last pos:", C.bad, "left", 0)
      fitText(x + 4, y + hh, w - 8, hh, string.format("%.5f,%.5f", wd.lastPos.lat, wd.lastPos.lon), C.warn, "left", 0)
    else
      fitText(x + 4, y, w - 8, h, "No telem", C.bad, "left", MIDSIZE)
    end
    return
  end
  fitText(x + 4, y, w * 0.6 - 4, hh, t.dist and fmtDist(t.dist) or "---", C.text, "left", MIDSIZE)
  fitText(x + w * 0.6, y, w * 0.4 - 4, hh, floor(t.rq) .. "%", rqColor(t.rq), "right", MIDSIZE)
  fitText(x + 4, y + hh, w * 0.5 - 4, hh, floor(t.sats) .. " sats", satColor(t.sats), "left", 0)
  fitText(x + w * 0.5, y + hh, w * 0.5 - 4, hh, floor(t.mah) .. "mAh", C.text, "right", 0)
end

---------------------------------------------------------------- widget API
local function create(zone, opts)
  local wd = { zone = zone, options = opts, t = { cell = 0, conn = false, fm = "----" },
               wasConn = false, armedPrev = false, lastWarn = 0, lastRangeWarn = 0 }
  resetFlight(wd)
  return wd
end

local function update(wd, opts)
  wd.options = opts
  wd.cells = 0
end

local function background(wd)
  tick(wd)   -- keeps home, distance and alerts running when the screen isn't shown
end

local function refresh(wd, event, touchState)
  tick(wd)
  if wd.zone.w >= 300 and wd.zone.h >= 150 then
    drawFull(wd)
  else
    drawCompact(wd)
  end
end

return { name = name, options = options, create = create,
         update = update, refresh = refresh, background = background }
