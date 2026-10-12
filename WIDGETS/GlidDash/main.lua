-- GlideDash: RC glider telemetry dashboard for EdgeTX colour radios
-- Install to the SD card as: /WIDGETS/GlidDash/main.lua
-- (EdgeTX allows widget folder names of 8 characters at most; it still shows as GlideDash)
-- Sensors (change the names below if yours differ): Alt, VSpd, RxBt, RQly, 1RSS
-- If there is no VSpd sensor, vertical speed is worked out from altitude.

local name = "GlideDash"

local S_ALT, S_VSPD, S_RXBT, S_LQ, S_RSSI = "Alt", "VSpd", "RxBt", "RQly", "1RSS"

local HIST_SECS   = 2      -- altitude trace: one sample every 2 s ...
local HIST_LEN    = 150    -- ... 150 samples = 5 minutes
local RADIUS      = 5      -- corner rounding

local options = {
  { "LowRxV",   VALUE, 35, 0, 120 }, -- RX battery warning in tenths of a volt (35 = 3.5V), 0 = off
  { "VarioRng", VALUE, 5,  1, 10 },  -- vario bar full scale, m/s
  { "AvgSecs",  VALUE, 20, 5, 60 },  -- climb averager window, seconds
  { "Alerts",   BOOL,  1 },          -- beep + vibrate on low RX battery
  { "BigText",  BOOL,  1 },          -- off = every value one font size smaller
}

local C = {
  bg    = lcd.RGB(16, 18, 24),
  panel = lcd.RGB(32, 36, 46),
  off   = lcd.RGB(58, 64, 78),
  text  = lcd.RGB(236, 239, 244),
  dim   = lcd.RGB(140, 148, 162),
  good  = lcd.RGB(40, 200, 100),
  warn  = lcd.RGB(255, 176, 0),
  bad   = lcd.RGB(232, 52, 52),
  trace = lcd.RGB(0, 190, 255),
  fill  = lcd.RGB(30, 70, 95),
}

local floor = math.floor

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
  if w > 0 and h > 0 then
    lcd.drawFilledRectangle(floor(x), floor(y), floor(w), floor(h), color)
  end
end

-- filled rectangle with small rounded corners, built from 1px rows
local function rbox(x, y, w, h, color, r)
  x, y, w, h = floor(x), floor(y), floor(w), floor(h)
  r = math.min(r or RADIUS, floor(w / 2), floor(h / 2))
  if r < 1 then box(x, y, w, h, color) return end
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

local function fmtV(v)                       -- vertical speed with sign
  if v >= 0.05 then return string.format("+%.1f", v) end
  if v <= -0.05 then return string.format("%.1f", v) end
  return "0.0"
end

local function varioColor(v)
  if v >= 0.2 then return C.good end
  if v > -1.0 then return C.text end
  return C.bad
end

local function rqColor(rq)
  if rq >= 80 then return C.good elseif rq >= 50 then return C.warn end
  return C.bad
end

---------------------------------------------------------------- telemetry
local function resetFlight(wd)
  wd.ground, wd.maxAlt = nil, 0
  wd.state, wd.launchMax, wd.launchH = "ground", 0, nil
  wd.sinkSince, wd.lowSince = nil, nil
  wd.avg, wd.lastT = 0, nil
  wd.dAlt, wd.dT, wd.dV = nil, nil, 0
  wd.hist, wd.histT = {}, 0
  wd.hasVSpd = getFieldInfo(S_VSPD) ~= nil
end

local function tick(wd)
  local t = wd.t
  local now = getTime()                          -- 10 ms units
  t.rq   = num(S_LQ)
  t.conn = t.rq > 0 and telemetryUp()
  t.rss  = num(S_RSSI)
  t.rxv  = num(S_RXBT)

  local fmIdx, fmName = getFlightMode()
  t.fm = (fmName and fmName ~= "") and fmName or ("FM" .. (fmIdx or 0))

  if t.conn and not wd.wasConn then resetFlight(wd) end
  wd.wasConn = t.conn
  if not t.conn then wd.lastT = nil return end

  -- altitude relative to where the model was when telemetry connected
  local rawAlt = num(S_ALT)
  if wd.ground == nil then wd.ground = rawAlt end
  t.alt = rawAlt - wd.ground
  wd.maxAlt = math.max(wd.maxAlt, t.alt)

  -- vertical speed: sensor if present, otherwise derived from altitude
  if wd.hasVSpd then
    t.vs = num(S_VSPD)
  else
    if wd.dT == nil then
      wd.dAlt, wd.dT = t.alt, now
    elseif now - wd.dT >= 50 then
      local raw = (t.alt - wd.dAlt) / ((now - wd.dT) / 100)
      wd.dV = wd.dV + (raw - wd.dV) * 0.5
      wd.dAlt, wd.dT = t.alt, now
    end
    t.vs = wd.dV
  end

  -- climb averager (time-based moving average)
  if wd.lastT then
    local dt = (now - wd.lastT) / 100
    local k = clamp(dt / wd.options.AvgSecs, 0, 1)
    wd.avg = wd.avg + (t.vs - wd.avg) * k
  end
  wd.lastT = now

  -- launch detection: climb starts -> track peak -> lock it when sinking for 1 s
  if wd.state == "ground" then
    if t.alt > 5 and t.vs > 1 then
      wd.state, wd.launchMax, wd.sinkSince = "launch", t.alt, nil
    end
  elseif wd.state == "launch" then
    wd.launchMax = math.max(wd.launchMax, t.alt)
    if t.vs < -0.3 then
      wd.sinkSince = wd.sinkSince or now
      if now - wd.sinkSince >= 100 then
        wd.launchH, wd.state, wd.lowSince = wd.launchMax, "flying", nil
      end
    else
      wd.sinkSince = nil
    end
  elseif wd.state == "flying" then
    if t.alt < 3 then                             -- landed after 10 s near the ground
      wd.lowSince = wd.lowSince or now
      if now - wd.lowSince >= 1000 then wd.state = "ground" end
    else
      wd.lowSince = nil
    end
  end

  -- altitude history for the trace
  if now - wd.histT >= HIST_SECS * 100 then
    wd.histT = now
    local h = wd.hist
    h[#h + 1] = t.alt
    if #h > HIST_LEN then table.remove(h, 1) end
  end

  -- low RX battery alert
  local low = wd.options.LowRxV / 10
  if wd.options.Alerts == 1 and low > 0 and t.rxv > 0.5 and t.rxv < low
     and now - wd.lastWarn > 1500 then
    playTone(1600, 250, 100, PLAY_NOW)
    playHaptic(40, 0)
    wd.lastWarn = now
  end
end

---------------------------------------------------------------- drawing
local FONTS = { XXLSIZE, DBLSIZE, MIDSIZE, 0, SMLSIZE }

-- Draw s in the box (x, y, w, h) with the biggest font (up to maxFont) that fits.
-- If tmpl is given, the font is chosen to fit tmpl, so the size stays steady.
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

-- vertical vario gauge: fills up (climb) or down (sink) from the centre line
local function varioBar(x, y, w, h, v, range, color)
  rbox(x, y, w, h, C.off, 3)
  local mid = y + h / 2
  local frac = clamp(v / range, -1, 1)
  local fillH = (h / 2) * math.abs(frac)
  if frac > 0 then rbox(x, mid - fillH, w, fillH, color, 2)
  elseif frac < 0 then rbox(x, mid, w, fillH, color, 2) end
  box(x - 3, mid, w + 6, 2, C.text)
end

local function drawTrace(wd, x, y, w, h)
  local hist = wd.hist
  local n = #hist
  if n < 2 then
    fitText(x, y, w, h, "altitude trace starts after launch", C.dim, "center", SMLSIZE)
    return
  end
  local top = 20
  for i = 1, n do top = math.max(top, hist[i]) end
  top = top * 1.25
  local colW = w / HIST_LEN
  local x0 = x + w - n * colW                   -- newest sample on the right
  local px, py
  for i = 1, n do
    local a = math.max(0, hist[i])
    local cx = x0 + (i - 1) * colW
    local cy = y + h - h * a / top
    box(cx, cy, colW + 1, y + h - cy, C.fill)
    if px then line(px, py, cx, cy, C.trace) end
    px, py = cx, cy
  end
  if wd.launchH then                             -- dashed launch-height marker
    local ly = y + h - h * wd.launchH / top
    for dx = 0, w - 1, 8 do box(x + dx, ly, 4, 1, C.warn) end
  end
  text(x + 2, y, floor(top / 1.25) .. "m  |  last 5 min", SMLSIZE + C.dim)
end

local function drawFull(wd)
  local z, t = wd.zone, wd.t
  local x, y, w, h = z.x, z.y, z.w, z.h
  local p, inner = 6, 8
  local conn = t.conn
  local _, lh = lcd.sizeText("A", SMLSIZE)

  local bigOn  = wd.options.BigText == 1
  local F_HUGE = bigOn and XXLSIZE or DBLSIZE
  local F_BIG  = bigOn and DBLSIZE or MIDSIZE
  local F_MID  = bigOn and MIDSIZE or 0

  box(x, y, w, h, C.bg)

  -- top bar: radio flight mode | timer | link pill
  local topH = floor(h * 0.15)
  rbox(x, y, w, topH, C.panel)
  fitText(x + inner, y + 3, w * 0.36, topH - 6, conn and t.fm or "NO TELEMETRY",
    conn and C.text or C.bad, "left", F_BIG)
  local tm = model.getTimer(0)
  fitText(x + w * 0.40, y + 3, w * 0.20, topH - 6, mmss(tm and tm.value or 0), C.text, "center", F_MID)
  local pw = floor(w * 0.24)
  local px = x + w - pw - p
  rbox(px, y + p, pw, topH - p * 2, conn and rqColor(t.rq) or C.off, 4)
  fitText(px + 4, y + p, pw - 8, topH - p * 2, conn and ("LQ " .. floor(t.rq) .. "%") or "NO LINK",
    conn and C.bg or C.text, "center", F_MID)

  -- middle row geometry
  local midY   = y + topH + p
  local midH   = floor(h * 0.40)
  local aw     = floor((w - 2 * p) * 0.36)
  local cw     = floor((w - 2 * p) * 0.36)
  local labelH = lh + 6
  local lineH  = math.max(lh + 4, floor(midH * 0.22))
  local valY   = midY + labelH
  local valH   = midH - labelH - lineH - 4
  local lineY  = midY + midH - lineH - 2

  -- altitude panel
  local ax = x
  rbox(ax, midY, aw, midH, C.panel)
  text(ax + inner, midY + 4, "ALTITUDE", SMLSIZE + C.dim)
  fitText(ax + inner, valY, aw - inner * 2, valH,
    conn and (floor(t.alt + 0.5) .. "m") or "---", C.text, "left", F_HUGE, "888m")
  local st = (wd.state == "launch") and "LAUNCHING" or ((wd.state == "flying") and "FLYING" or "ON GROUND")
  fitText(ax + inner, lineY, aw - inner * 2, lineH, st,
    wd.state == "launch" and C.warn or C.dim, "left", F_MID)

  -- vario panel
  local vx = ax + aw + p
  local range = wd.options.VarioRng
  local vs = conn and t.vs or 0
  local vCol = conn and varioColor(vs) or C.dim
  rbox(vx, midY, cw, midH, C.panel)
  text(vx + inner, midY + 4, "VARIO m/s", SMLSIZE + C.dim)
  local gW = math.max(10, floor(cw * 0.10))
  local gX = vx + cw - inner - gW
  varioBar(gX, valY, gW, midH - labelH - p, vs, range, vs >= 0 and C.good or C.bad)
  fitText(vx + inner, valY, cw - inner * 2 - gW - 8, valH,
    conn and fmtV(vs) or "--", vCol, "left", F_HUGE, "+8.8")
  fitText(vx + inner, lineY, cw - inner * 2 - gW - 8, lineH, "scale " .. range, C.dim, "left", SMLSIZE)

  -- averager panel
  local gx2 = vx + cw + p
  local gw2 = x + w - gx2
  local avg = conn and wd.avg or 0
  rbox(gx2, midY, gw2, midH, C.panel)
  text(gx2 + inner, midY + 4, "AVG " .. wd.options.AvgSecs .. "s", SMLSIZE + C.dim)
  fitText(gx2 + inner, valY, gw2 - inner * 2, valH,
    conn and fmtV(avg) or "--", conn and varioColor(avg) or C.dim, "left", F_HUGE, "+8.8")
  local hint, hintCol = "", C.dim
  if conn and avg >= 0.5 then hint, hintCol = "THERMAL", C.good
  elseif conn and avg <= -1.5 then hint, hintCol = "SINK", C.bad end
  fitText(gx2 + inner, lineY, gw2 - inner * 2, lineH, hint, hintCol, "left", F_MID)

  -- tiles row
  local botY = midY + midH + p
  local botH = floor(h * 0.20)
  local tw = (w - p * 3) / 4
  local low = wd.options.LowRxV / 10
  local rxCol = C.text
  if conn and low > 0 and t.rxv > 0.5 and t.rxv < low then rxCol = C.bad end
  local launchTxt, launchCol = "--", C.text
  if wd.state == "launch" then launchTxt, launchCol = floor(wd.launchMax + 0.5) .. "m", C.warn
  elseif wd.launchH then launchTxt = floor(wd.launchH + 0.5) .. "m" end
  local tiles = {
    { "MAX ALT",  wd.maxAlt > 0 and (floor(wd.maxAlt + 0.5) .. "m") or "--", C.text, "888m" },
    { "LAUNCH",   launchTxt, launchCol, "888m" },
    { "RX BATT",  conn and string.format("%.2fV", t.rxv) or "--", conn and rxCol or C.dim, "8.88V" },
    { "RSSI dBm", conn and tostring(floor(t.rss)) or "--", C.text, "-888" },
  }
  for i, tl in ipairs(tiles) do
    local tx = x + (i - 1) * (tw + p)
    rbox(tx, botY, tw, botH, C.panel)
    fitText(tx + 6, botY + 3, tw - 12, lh + 2, tl[1], C.dim, "left", SMLSIZE)
    fitText(tx + 6, botY + labelH, tw - 12, botH - labelH - 4, tl[2], tl[3], "center", F_BIG, tl[4])
  end

  -- altitude trace
  local sy = botY + botH + p
  local sh = y + h - sy
  if sh >= 30 then
    rbox(x, sy, w, sh, C.panel)
    drawTrace(wd, x + inner, sy + 4, w - inner * 2, sh - 8)
  end
end

-- small zones: altitude and vario only
local function drawCompact(wd)
  local z, t = wd.zone, wd.t
  local x, y, w, h = z.x, z.y, z.w, z.h
  rbox(x, y, w, h, C.panel)
  if not t.conn then
    fitText(x + 4, y, w - 8, h, "No telem", C.bad, "left", MIDSIZE)
    return
  end
  fitText(x + 4, y, w * 0.55 - 4, h, floor(t.alt + 0.5) .. "m", C.text, "left", DBLSIZE)
  fitText(x + w * 0.55, y, w * 0.45 - 4, h, fmtV(t.vs), varioColor(t.vs), "right", DBLSIZE)
end

---------------------------------------------------------------- widget API
local function create(zone, opts)
  local wd = { zone = zone, options = opts, t = { conn = false, alt = 0, vs = 0 },
               wasConn = false, lastWarn = 0 }
  resetFlight(wd)
  return wd
end

local function update(wd, opts)
  wd.options = opts
end

local function background(wd)
  tick(wd)
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
