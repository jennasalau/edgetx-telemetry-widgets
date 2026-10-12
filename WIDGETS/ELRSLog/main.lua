-- ELRSLog: logs every time the 2.4GHz or 900MHz side of an ELRS Gemini link drops out,
-- and every time the whole link is lost. For EdgeTX colour radios.
-- Install to the SD card as: /WIDGETS/ELRSLog/main.lua
-- Sensors used: 1RSS, 2RSS, RQly, FM, GPS, Sats  (run "Discover new sensors" first)
--
-- Log files: /LOGS/ELRSLog-YYYY-MM-DD.csv, one per day, shared by all models. Each row records
--   the model name; each model's screen and day browser only show that model's events.
--   A LOST row is written the moment a dropout starts, and a BACK row (with the duration)
--   when it recovers, so nothing is lost if the radio is switched off or the link never returns.
--   last_value is the band's last dBm before the drop, or the last LQ % for LINK.
--
-- Audio: put the sounds folder next to this file to hear "two point four lost", "nine hundred back"
-- etc. Without it (or with Audio = 2) a tone plays instead: high = 2.4GHz, low = 900MHz.
--
-- ArmedOnly (on by default): nothing is logged or announced while disarmed, so unplugging the
-- battery after landing isn't recorded as a link loss. A dropout that starts while armed is always
-- logged in full. Arming is read from Betaflight's flight mode, so untick it for a plane or any
-- model that doesn't report arming, otherwise nothing will be logged.
--
-- Normal view: today's events (reloaded from the SD card at power-up) plus live ones.
-- Full screen (long-press the widget, choose "Full screen"; or select it and press ENTER):
--   browse older days.
--   Rotary / tap the table: scroll.  Rotary press, PAGE keys or tap < > in the title: change day.
--   Long-press RTN to leave full screen.

local name       = "ELRSLog"
local LOG_DIR    = "/LOGS"
local MAX_EVENTS = 100    -- events kept per day on screen (the CSV keeps everything)
local DEBOUNCE   = 20     -- a band must stay below the threshold this long to count (10 ms units = 0.2 s)
local RECOVER_DB = 3      -- and climb this many dB back above it to count as recovered
local MIN_SATS   = 6
local READ_CHUNK = 1024   -- bytes read per screen refresh when loading a log file
local RADIUS     = 5
local SOUND_DIR  = "/WIDGETS/ELRSLog/sounds/"   -- lost24.wav, lost900.wav, back24.wav, back900.wav
local SAY_GAP    = 300    -- don't repeat a band's announcement within 3 s (10 ms units)
local SAY_BACK_MIN = 1.0  -- only announce recovery after a dropout at least this long (seconds)

local options = {
  { "LostDBm",  VALUE, -115, -130, -90 }, -- at or below this, a band counts as lost
  { "Bands",    VALUE, 1, 0, 3 },         -- 0 Gemini swapped, 1 Gemini X (900 = 1RSS), 2 = 2.4 only, 3 = 900 only
  { "Audio",    VALUE, 1, 0, 2 },         -- 0 = silent, 1 = voice ("two point four lost"), 2 = tones only
  { "SayBack",  BOOL,  1 },               -- also say "... back" when a band recovers (drops of 1 s or more)
  { "ArmedOnly", BOOL, 1 },               -- only log/announce while armed (untick for planes without arming)
}

local C = {
  bg    = lcd.RGB(16, 18, 24),
  panel = lcd.RGB(32, 36, 46),
  row   = lcd.RGB(40, 45, 57),
  off   = lcd.RGB(58, 64, 78),
  text  = lcd.RGB(236, 239, 244),
  dim   = lcd.RGB(140, 148, 162),
  good  = lcd.RGB(40, 200, 100),
  warn  = lcd.RGB(255, 176, 0),
  bad   = lcd.RGB(232, 52, 52),
  badBg = lcd.RGB(88, 30, 34),
}

local floor, rad, sin, cos = math.floor, math.rad, math.sin, math.cos

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

local function box(x, y, w, h, color)
  if w > 0 and h > 0 then
    lcd.drawFilledRectangle(floor(x), floor(y), floor(w), floor(h), color)
  end
end

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

local function mmss(s)
  s = math.max(0, floor(s))
  return string.format("%02d:%02d", floor(s / 60), s % 60)
end

local function fmtDur(s)
  if s < 10 then return string.format("%.1fs", s) end
  if s < 60 then return floor(s) .. "s" end
  return mmss(s)
end

-- time since arm, e.g. 3:12.4 (tenths, for lining up with DVR footage)
local function fmtArm(sec)
  if not sec then return "--" end
  local tenths = floor(sec * 10 + 0.5)
  local m, rest = floor(tenths / 600), tenths % 600
  return string.format("%d:%02d.%d", m, floor(rest / 10), rest % 10)
end

local function fmtDist(m)
  if not m then return "--" end
  if m < 1000 then return floor(m + 0.5) .. "m" end
  return string.format("%.2fkm", m / 1000)
end

local function dist(lat1, lon1, lat2, lon2)
  local dlat, dlon = rad(lat2 - lat1), rad(lon2 - lon1)
  local a = sin(dlat / 2) ^ 2 + cos(rad(lat1)) * cos(rad(lat2)) * sin(dlon / 2) ^ 2
  return 2 * 6371000 * math.asin(math.sqrt(a))
end

local function timerValue()
  local tm = model.getTimer(0)
  return tm and tm.value or 0
end

-- current model's name, made safe for a CSV field
local function modelName()
  local ok, info = pcall(model.getInfo)
  local n = ok and type(info) == "table" and info.name or ""
  n = string.gsub(n or "", "[,\r\n]", " ")
  return n
end

local function dateStr(d)
  return string.format("%04d-%02d-%02d", d.year, d.mon, d.day)
end

local function pathFor(ds)
  return LOG_DIR .. "/ELRSLog-" .. ds .. ".csv"
end

-- split a CSV line, keeping empty fields
local function split(line)
  local out, i = {}, 1
  while true do
    local j = string.find(line, ",", i, true)
    if not j then out[#out + 1] = string.sub(line, i) return out end
    out[#out + 1] = string.sub(line, i, j - 1)
    i = j + 1
  end
end

---------------------------------------------------------------- CSV writing
local HEADER = "date,time,event,arm_no,since_arm,since_arm_s,flight_timer,band,lost_for_s,"
            .. "last_value,other_band_dbm,min_lq,armed,lat,lon,dist_from_first_fix_m,model\n"

local function appendLine(path, line)
  local isNew = true
  local fr = io.open(path, "r")
  if fr then io.close(fr) isNew = false end
  local f = io.open(path, "a")
  if not f then return end
  if isNew then io.write(f, HEADER) end
  io.write(f, line)
  io.close(f)
end

local function csvRow(wd, kind, ev, d, sinceArm, timer, lat, lon, dst)
  return string.format("%04d-%02d-%02d,%02d:%02d:%02d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%d,%s,%s,%s,%s,%s\n",
    d.year, d.mon, d.day, d.hour, d.min, d.sec, kind,
    ev.armNo and tostring(ev.armNo) or "",
    sinceArm and fmtArm(sinceArm) or "",
    sinceArm and string.format("%.1f", sinceArm) or "",
    mmss(timer), ev.band,
    kind == "BACK" and string.format("%.1f", ev.dur or 0) or "",
    ev.before and tostring(floor(ev.before)) or "",
    ev.other and tostring(floor(ev.other)) or "",
    floor(ev.minLQ or 0), ev.armed and "yes" or "no",
    lat and string.format("%.6f", lat) or "", lon and string.format("%.6f", lon) or "",
    dst and tostring(floor(dst + 0.5)) or "", wd.model)
end

-- while today's file is still being read back, hold new rows so they aren't read twice
local function logRow(wd, line)
  if wd.todayLd and not wd.todayLd.done then
    wd.writeQ[#wd.writeQ + 1] = line
  else
    appendLine(wd.todayPath, line)
  end
end

---------------------------------------------------------------- CSV reading
-- Reads a day's file a chunk at a time (so a big file can't stall the radio) and pairs
-- each LOST row with its BACK row. Also reads files written by earlier versions.
local function parseRow(f)
  local n = #f
  local kind, armNo, since, band, dur, last, other, minlq, dst, mdl
  if n >= 17 then mdl = f[17] end
  if n >= 16 then
    kind, armNo, since, band, dur, last, other, minlq, dst = f[3], f[4], f[6], f[8], f[9], f[10], f[11], f[12], f[16]
  elseif n == 15 then
    kind, armNo, since, band, dur, last, other, minlq, dst = "DONE", f[3], f[5], f[7], f[8], f[9], f[10], f[11], f[15]
  elseif n == 12 then
    kind, band, dur, last, other, minlq, dst = "DONE", f[4], f[5], f[6], f[7], f[8], f[12]
  else
    return nil
  end
  local h, m, s = string.match(f[2] or "", "^(%d+):(%d+):(%d+)$")
  if not h then return nil end                 -- header or broken line
  return kind, {
    band = band, clock = { hour = tonumber(h), min = tonumber(m), sec = tonumber(s) },
    armNo = tonumber(armNo), sinceArm = tonumber(since), dur = tonumber(dur),
    before = tonumber(last), other = tonumber(other), minLQ = tonumber(minlq), dist = tonumber(dst),
    model = mdl,
  }
end

-- model: only keep rows from this model (rows logged before models were recorded are kept too)
local function newLoader(path, model)
  return { path = path, model = model, buf = "", list = {}, open = {}, done = false }
end

local function loaderLine(ld, line)
  line = string.gsub(line, "\r", "")
  local kind, ev = parseRow(split(line))
  if not kind then return end
  if ld.model and ev.model and ev.model ~= ld.model then return end
  if kind == "BACK" then
    local o = ld.open[ev.band]
    if o then o.dur, o.minLQ, ld.open[ev.band] = ev.dur, ev.minLQ, nil end
    return
  end
  if kind == "LOST" then ev.dur = nil ld.open[ev.band] = ev end
  ld.list[#ld.list + 1] = ev
  if #ld.list > MAX_EVENTS then table.remove(ld.list, 1) end
end

local function loaderFinish(ld)
  if ld.f then io.close(ld.f) ld.f = nil end
  if ld.buf ~= "" then loaderLine(ld, ld.buf) ld.buf = "" end
  local out = {}
  for i = #ld.list, 1, -1 do                    -- newest first
    local ev = ld.list[i]
    if ev.dur == nil then ev.noRecovery = true end
    out[#out + 1] = ev
  end
  ld.list, ld.open, ld.done = out, nil, true
end

local function loaderStep(ld)
  if not ld or ld.done then return end
  if not ld.f then
    ld.f = io.open(ld.path, "r")
    if not ld.f then loaderFinish(ld) return end
  end
  local chunk = io.read(ld.f, READ_CHUNK)
  if not chunk or #chunk == 0 then loaderFinish(ld) return end
  ld.buf = ld.buf .. chunk
  while true do
    local nl = string.find(ld.buf, "\n", 1, true)
    if not nl then break end
    loaderLine(ld, string.sub(ld.buf, 1, nl - 1))
    ld.buf = string.sub(ld.buf, nl + 1)
  end
end

-- when today's file has been read back: merge it under the live events and flush held rows
local function todayLoaded(wd)
  -- carry the arm count on from earlier sessions today, so #numbers keep matching video files
  local base = 0
  for _, ev in ipairs(wd.todayLd.list) do
    if ev.armNo and ev.armNo > base then base = ev.armNo end
  end
  if base > 0 then
    for _, ev in ipairs(wd.events) do               -- anything logged while the file was loading
      if ev.armNo then ev.armNo = ev.armNo + base end
    end
    wd.armNo = wd.armNo + base
  end
  for _, ev in ipairs(wd.todayLd.list) do
    if #wd.events >= MAX_EVENTS then break end
    wd.events[#wd.events + 1] = ev
  end
  for _, line in ipairs(wd.writeQ) do appendLine(wd.todayPath, line) end
  wd.writeQ, wd.todayMerged = {}, true
end

---------------------------------------------------------------- event tracking
local function newBand(label, tone, key)
  return { name = label, tone = tone, key = key, seen = false, lost = false, lastSaid = -10000 }
end

-- voice clip if it's on the SD card and Voice is ticked, otherwise the tone (for "lost" only)
local function announce(wd, b, what)
  local clip = b.key and wd.snd[what .. b.key]
  local mode = wd.options.Audio
  if mode == 1 and clip then playFile(clip) return true end
  if what == "lost" and mode >= 1 and b.tone then
    playTone(b.tone, 150, 50, PLAY_NOW)
    return true
  end
  return false
end

local function startEvent(wd, b, t0, other)
  local t = wd.t
  local armed = wd.armedNow
  local ev = { band = b.name, t0 = t0, timer = timerValue(), clock = getDateTime(),
               before = b.lastGood, other = other, minLQ = t.rq, armed = armed,
               armNo = armed and wd.armNo or nil,
               sinceArm = armed and math.max(0, (t0 - wd.armT) / 100) or nil,
               lat = t.lat, lon = t.lon, dist = t.dist, live = true }
  b.lost, b.cur = true, ev
  table.insert(wd.events, 1, ev)
  if #wd.events > MAX_EVENTS then table.remove(wd.events) end
  logRow(wd, csvRow(wd, "LOST", ev, ev.clock, ev.sinceArm, ev.timer, t.lat, t.lon, t.dist))
  b.saidLost = false
  local now = getTime()
  if b.key and now - b.lastSaid >= SAY_GAP and announce(wd, b, "lost") then
    b.saidLost, b.lastSaid = true, now
    playHaptic(20, 0)
  end
end

local function endEvent(wd, b, tEnd, quiet)
  local ev, t = b.cur, wd.t
  if not ev then return end
  ev.dur = math.max(0, (tEnd - ev.t0) / 100)
  b.lost, b.cur, b.below, b.above = false, nil, nil, nil
  local sinceArm = (ev.armNo and ev.armNo == wd.armNo) and math.max(0, (tEnd - wd.armT) / 100) or nil
  logRow(wd, csvRow(wd, "BACK", ev, getDateTime(), sinceArm, timerValue(), t.lat, t.lon, t.dist))
  if not quiet and b.saidLost and wd.options.SayBack == 1 and ev.dur >= SAY_BACK_MIN then
    announce(wd, b, "back")
  end
  b.saidLost = false
end

local function canLog(wd)
  return wd.options.ArmedOnly ~= 1 or wd.armedNow
end

local function tick(wd)
  local t, now = wd.t, getTime()

  -- read today's file back in the background, a chunk per call
  if wd.todayLd and not wd.todayMerged then
    loaderStep(wd.todayLd)
    if wd.todayLd.done then todayLoaded(wd) end
  end

  t.rq   = num("RQly")
  t.conn = t.rq > 0 and telemetryUp()

  local r1, r2 = num("1RSS"), num("2RSS")
  t.r24, t.r900 = splitBands(wd.options.Bands, r1, r2)

  local fm = getValue("FM")
  if t.conn and type(fm) == "string" and fm ~= "" then wd.sawFM = true end
  t.armed = t.conn and type(fm) == "string" and fm ~= "" and string.sub(fm, -1) ~= "*"

  -- position at the time of each event, and distance from the first good fix this session
  local g = getValue("GPS")
  if t.conn and type(g) == "table" and g.lat and g.lon and (g.lat ~= 0 or g.lon ~= 0) then
    t.lat, t.lon = g.lat, g.lon
    if not wd.home and num("Sats") >= MIN_SATS then wd.home = { lat = g.lat, lon = g.lon } end
    t.dist = wd.home and dist(g.lat, g.lon, wd.home.lat, wd.home.lon) or nil
  end

  local bands = { wd.b24, wd.b900 }
  local link = wd.link

  -- whole link lost: close any band dropouts at that moment and log one LINK event
  if not t.conn then
    if wd.wasConn and not link.lost then
      for _, b in ipairs(bands) do
        if b.lost then endEvent(wd, b, now, true) end
        b.seen, b.below, b.above = false, nil, nil
      end
      link.lastGood = wd.lastRQ
      if canLog(wd) then startEvent(wd, link, now, nil) end   -- armedNow = state just before the loss
    end
    wd.wasConn = false
    return
  end
  if link.lost then endEvent(wd, link, now) end
  wd.wasConn, wd.lastRQ = true, t.rq

  -- arm clock: only updated while telemetry is up, so a link loss doesn't look like a disarm
  if t.armed and not wd.armedNow then wd.armNo, wd.armT = wd.armNo + 1, now end
  wd.armedNow = t.armed

  local thr = wd.options.LostDBm
  local vals = { t.r24, t.r900 }
  for i, b in ipairs(bands) do
    local v, other = vals[i], vals[3 - i]
    if v == nil then                           -- band not used on this model
      if b.lost then endEvent(wd, b, now, true) end
      b.seen, b.below, b.above = false, nil, nil
    else
    local bad = (v >= 0) or (v <= thr)        -- 0 = no reading from that band
    if not b.lost then
      if not bad then
        b.seen, b.lastGood, b.below = true, v, nil
      elseif b.seen then                        -- only after the band has been seen working
        if canLog(wd) then
          b.below = b.below or now
          if now - b.below >= DEBOUNCE then startEvent(wd, b, b.below, other) end
        else
          b.below = nil
        end
      end
    else
      b.cur.minLQ = math.min(b.cur.minLQ, t.rq)
      if v < 0 and v > thr + RECOVER_DB then
        b.above = b.above or now
        if now - b.above >= DEBOUNCE then endEvent(wd, b, b.above) end
      else
        b.above = nil
      end
    end
    end
  end
end

---------------------------------------------------------------- day selector
local function scanDays(wd)
  local list = {}
  if type(dir) == "function" then
    pcall(function()
      for fname in dir(LOG_DIR) do
        local ds = string.match(fname, "^ELRSLog%-(%d%d%d%d%-%d%d%-%d%d)%.csv$")
        if ds and ds ~= wd.today then list[#list + 1] = ds end
      end
    end)
  end
  table.sort(list, function(a, b) return a > b end)
  wd.days = { wd.today }
  wd.scanQ, wd.scanLd, wd.cache = list, nil, {}
end

-- check queued day files for this model's events, a few chunks per refresh
local function scanStep(wd)
  for _ = 1, 4 do
    if not wd.scanQ or #wd.scanQ == 0 then return end
    local ds = wd.scanQ[1]
    wd.scanLd = wd.scanLd or newLoader(pathFor(ds), wd.model)
    loaderStep(wd.scanLd)
    if wd.scanLd.done then
      if #wd.scanLd.list > 0 then
        wd.days[#wd.days + 1] = ds
        wd.cache[ds] = wd.scanLd
      end
      table.remove(wd.scanQ, 1)
      wd.scanLd = nil
    end
  end
end

local function selectDay(wd, i)
  local n = #wd.days
  wd.vi = ((i - 1) % n) + 1
  wd.scroll = 0
  local ds = wd.days[wd.vi]
  wd.view = (wd.vi > 1) and ((wd.cache and wd.cache[ds]) or newLoader(pathFor(ds), wd.model)) or nil
end

-- the event list currently on screen (nil while a past day is still loading)
local function viewEvents(wd)
  if wd.vi == 1 then return wd.events end
  if wd.view and wd.view.done then return wd.view.list end
  return nil
end

local function stats(list)
  local s = { ["2.4G"] = { n = 0, tot = 0, open = 0 }, ["900M"] = { n = 0, tot = 0, open = 0 },
              LINK = { n = 0, tot = 0, open = 0 } }
  for _, ev in ipairs(list or {}) do
    local b = s[ev.band]
    if b then
      b.n = b.n + 1
      if ev.dur then b.tot = b.tot + ev.dur elseif ev.noRecovery then b.open = b.open + 1 end
    end
  end
  return s
end

---------------------------------------------------------------- drawing
local FONTS = { XXLSIZE, DBLSIZE, MIDSIZE, 0, SMLSIZE }

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

local function totalText(st)
  local s = st.tot > 0 and fmtDur(st.tot) or ""
  if st.open > 0 then s = s .. (s ~= "" and " + " or "") .. st.open .. " no recovery" end
  return s
end

local function drawCard(wd, b, st, x, y, w, h, live, liveTmpl, lh, isToday, unused)
  local lost = isToday and b.lost
  rbox(x, y, w, h, lost and C.badBg or C.panel)
  fitText(x + 8, y + 4, w * 0.5, lh + 2, b.name, C.dim, "left", SMLSIZE)
  local word = b.name == "LINK" and (st.n == 1 and "loss" or "losses") or (st.n == 1 and "drop" or "drops")
  local valH = h - (lh + 8) * 2
  if isToday then
    local status, sCol
    if unused then status, sCol, live = "OFF", C.dim, nil
    elseif lost then status, sCol = "LOST " .. fmtDur((getTime() - b.cur.t0) / 100), C.bad
    elseif live then status, sCol = "OK", C.good
    else status, sCol = "--", C.dim end
    fitText(x + w * 0.4, y + 4, w * 0.6 - 8, lh + 2, status, sCol, "right", SMLSIZE)
    fitText(x + 8, y + lh + 8, w - 16, valH, unused and "not used" or (live or "--"),
      lost and C.bad or (unused and C.off or C.text), "left", DBLSIZE, liveTmpl)
    local tot = st.n > 0 and ("  " .. totalText(st)) or ""
    fitText(x + 8, y + h - lh - 6, w - 16, lh + 2, st.n .. " " .. word .. " today" .. tot, C.dim, "left", SMLSIZE)
  else
    fitText(x + 8, y + lh + 8, w - 16, valH, st.n .. " " .. word, st.n > 0 and C.text or C.dim,
      "left", DBLSIZE, "88 losses")
    fitText(x + 8, y + h - lh - 6, w - 16, lh + 2,
      st.n > 0 and ((st.tot > 0 and "total " or "") .. totalText(st)) or "none", C.dim, "left", SMLSIZE)
  end
end

local COLS = { -- label, share of width, alignment
  { "ARM +",    0.20, "left" },
  { "BAND",     0.14, "left" },
  { "LOST FOR", 0.20, "left" },
  { "LAST",     0.15, "right" },
  { "OTHER",    0.15, "right" },
  { "DIST",     0.16, "right" },
}

local function drawFull(wd, fullscreen)
  local z, t = wd.dz, wd.t
  local x, y, w, h = z.x, z.y, z.w, z.h
  local p = 6
  local _, lh = lcd.sizeText("A", SMLSIZE)
  local isToday = wd.vi == 1
  local list = viewEvents(wd)
  local st = stats(list)
  box(x, y, w, h, C.bg)

  -- title bar
  local topH = floor(h * 0.11)
  rbox(x, y, w, topH, C.panel)
  if fullscreen then
    -- day selector:  [<]  2026-10-11 (today)  day 1 of 4  [>]
    local bw = floor(w * 0.12)
    local older, newer = wd.vi < #wd.days, wd.vi > 1
    rbox(x + p, y + p, bw, topH - 2 * p, older and C.off or C.row, 4)
    fitText(x + p, y + p, bw, topH - 2 * p, "<", older and C.text or C.off, "center", MIDSIZE)
    rbox(x + w - p - bw, y + p, bw, topH - 2 * p, newer and C.off or C.row, 4)
    fitText(x + w - p - bw, y + p, bw, topH - 2 * p, ">", newer and C.text or C.off, "center", MIDSIZE)
    local label = wd.days[wd.vi] .. (isToday and "  (today)" or "")
    fitText(x + bw + 2 * p + 6, y + 2, w * 0.5, topH - 4, label, C.text, "left", MIDSIZE)
    fitText(x + w * 0.6, y + 2, w * 0.4 - bw - 3 * p, topH - 4,
      "day " .. wd.vi .. " of " .. #wd.days .. ((wd.scanQ and #wd.scanQ > 0) and "  (checking...)" or ""),
      C.dim, "right", SMLSIZE)
  else
    fitText(x + 10, y + 2, w * 0.25, topH - 4, "LINK LOG", C.text, "left", MIDSIZE)
    local armTxt, armCol
    if wd.sawFM then
      armTxt = wd.armedNow and ("ARM #" .. wd.armNo .. "  +" .. fmtArm((getTime() - wd.armT) / 100))
               or (wd.armNo > 0 and "DISARMED" or "NOT ARMED")
      armCol = wd.armedNow and C.bad or C.dim
    else                                        -- plane / no arming reported
      armTxt = t.conn and "LOGGING" or "NO LINK"
      armCol = t.conn and C.good or C.dim
    end
    fitText(x + w * 0.27, y + 2, w * 0.25, topH - 4, armTxt, armCol, "left", 0)
    fitText(x + w * 0.54, y + 2, w * 0.46 - 10, topH - 4,
      "lost at " .. wd.options.LostDBm .. "dBm" .. (wd.options.ArmedOnly == 1 and "  |  armed only" or "")
        , C.dim, "right", SMLSIZE)
  end

  -- cards: 2.4G | 900M | LINK  (live readings today, totals for past days)
  local cardY = y + topH + p
  local cardH = floor(h * 0.25)
  local cw = (w - 2 * p) / 3
  local function dbm(v) return (t.conn and v and v < 0) and (floor(v) .. "dBm") or nil end
  drawCard(wd, wd.b24,  st["2.4G"], x,                cardY, cw, cardH, dbm(t.r24),  "-188dBm", lh, isToday,
    t.r24 == nil)
  drawCard(wd, wd.b900, st["900M"], x + cw + p,       cardY, cw, cardH, dbm(t.r900), "-188dBm", lh, isToday,
    t.r900 == nil)
  drawCard(wd, wd.link, st.LINK,    x + 2 * (cw + p), cardY, cw, cardH,
    t.conn and ("LQ " .. floor(t.rq) .. "%") or nil, "LQ 100%", lh, isToday)

  -- event table
  local ty = cardY + cardH + p
  local th = y + h - ty
  rbox(x, ty, w, th, C.panel)
  local rowH = lh + 12
  local hasArm = false
  for _, ev in ipairs(list or {}) do if ev.armNo then hasArm = true break end end
  if not list and wd.sawFM then hasArm = true end
  local firstLabel = hasArm and "ARM +" or "TIME"
  local cx, acc = {}, x + 10
  for i, c in ipairs(COLS) do cx[i] = acc acc = acc + (w - 20) * c[2] end
  for i, c in ipairs(COLS) do
    fitText(cx[i], ty + 4, (w - 20) * c[2] - 6, lh + 2, i == 1 and firstLabel or c[1], C.dim, c[3], SMLSIZE)
  end
  local ry = ty + lh + 10
  local maxRows = math.max(1, floor((ty + th - ry - lh - 8) / rowH))
  wd.lay = { topH = topH, ty = ty, th = th, rows = maxRows }
  fitText(x + 10, ty + th - lh - 6, w * 0.55, lh + 2,
    fullscreen and "hold RTN to go back" or "older days: hold widget > Full screen", C.dim, "left", SMLSIZE)

  if not list then
    fitText(x + 10, ry, w - 20, rowH * 2, "loading " .. wd.days[wd.vi] .. " ...", C.dim, "center", 0)
    return
  end
  if #list == 0 then
    local msg = isToday and (t.conn and "no dropouts yet today" or "waiting for telemetry") or "no events that day"
    fitText(x + 10, ry, w - 20, rowH * 2, msg, C.dim, "center", 0)
    return
  end

  wd.scroll = math.max(0, math.min(wd.scroll, #list - maxRows))
  for i = 1, math.min(maxRows, #list - wd.scroll) do
    local ev = list[wd.scroll + i]
    local active = isToday and ev.live and ev.dur == nil
    local red = active or ev.noRecovery
    if i % 2 == 1 or red then rbox(x + 4, ry, w - 8, rowH - 2, red and C.badBg or C.row, 3) end
    local d = ev.clock
    local lostFor
    if active then lostFor = "LOST " .. fmtDur((getTime() - ev.t0) / 100)
    elseif ev.noRecovery then lostFor = "NO RECOVERY"
    else lostFor = fmtDur(ev.dur or 0) end
    local cells = {
      ev.armNo and ("#" .. ev.armNo .. " " .. fmtArm(ev.sinceArm))
               or string.format("%02d:%02d:%02d", d.hour, d.min, d.sec),
      ev.band,
      lostFor,
      ev.before and (ev.band == "LINK" and (floor(ev.before) .. "%") or tostring(floor(ev.before))) or "--",
      ev.other and tostring(floor(ev.other)) or "--",
      fmtDist(ev.dist),
    }
    for j, c in ipairs(COLS) do
      local col = C.text
      if j == 1 and hasArm and not ev.armNo then col = C.dim   -- disarmed row among armed ones
      elseif j == 3 and red then col = C.bad
      elseif j == 2 and ev.band == "LINK" then col = C.bad
      elseif j >= 4 then col = C.dim end
      fitText(cx[j], ry, (w - 20) * c[2] - 6, rowH - 2, cells[j], col, c[3], 0)
    end
    ry = ry + rowH
  end
  if #list > maxRows then
    local last = math.min(#list, wd.scroll + maxRows)
    fitText(x + 10, ty + th - lh - 6, w - 20, lh + 2,
      (wd.scroll + 1) .. "-" .. last .. " of " .. #list .. (fullscreen and "  (scroll for more)" or ""),
      C.dim, "right", SMLSIZE)
  end
end

local function drawCompact(wd)
  local z = wd.dz
  local x, y, w, h = z.x, z.y, z.w, z.h
  rbox(x, y, w, h, C.panel)
  local st = stats(wd.events)
  local hh = h / 2
  local pw = (w - 8) / 3
  for i, b in ipairs({ wd.b24, wd.b900, wd.link }) do
    local px = x + 4 + (i - 1) * pw
    fitText(px, y, pw, hh, b.name .. (b.lost and " LOST" or ""), b.lost and C.bad or C.dim, "left", 0)
    fitText(px, y + hh, pw, hh, tostring(st[b.name].n), b.lost and C.bad or C.text, "left", MIDSIZE)
  end
end

---------------------------------------------------------------- input (full screen only)
local function handleEvent(wd, event, ts)
  local L = wd.lay
  local page = L and L.rows or 5
  if event == EVT_VIRTUAL_NEXT then wd.scroll = wd.scroll + 1
  elseif event == EVT_VIRTUAL_PREV then wd.scroll = math.max(0, wd.scroll - 1)
  elseif event == EVT_VIRTUAL_ENTER or event == EVT_VIRTUAL_NEXT_PAGE then selectDay(wd, wd.vi + 1)
  elseif event == EVT_VIRTUAL_PREV_PAGE then selectDay(wd, wd.vi - 1)
  elseif event == EVT_TOUCH_TAP and ts and L then
    local z = wd.dz
    local tx, ty = ts.x - z.x, ts.y - z.y
    if ty < L.topH then
      if tx < z.w * 0.2 and wd.vi < #wd.days then selectDay(wd, wd.vi + 1)        -- older
      elseif tx > z.w * 0.8 and wd.vi > 1 then selectDay(wd, wd.vi - 1) end       -- newer
    elseif ty >= L.ty - z.y then
      if ty < (L.ty - z.y) + L.th / 2 then wd.scroll = math.max(0, wd.scroll - page)
      else wd.scroll = wd.scroll + page end
    end
  elseif event == EVT_TOUCH_SLIDE and ts then
    if ts.swipeUp then wd.scroll = wd.scroll + page
    elseif ts.swipeDown then wd.scroll = math.max(0, wd.scroll - page) end
  end
end

---------------------------------------------------------------- widget API
local function create(zone, opts)
  local today = dateStr(getDateTime())
  local wd = { zone = zone, options = opts, t = { conn = false, rq = 0, r24 = 0, r900 = 0 },
               events = {}, writeQ = {}, wasConn = false, lastRQ = 0,
               armNo = 0, armT = 0, armedNow = false,
               b24 = newBand("2.4G", 2000, "24"), b900 = newBand("900M", 700, "900"),
               link = newBand("LINK", nil, nil),
               today = today, todayPath = pathFor(today), days = { today }, vi = 1, scroll = 0 }
  wd.model = modelName()
  wd.todayLd = newLoader(wd.todayPath, wd.model)
  wd.snd = {}
  for _, n in ipairs({ "lost24", "lost900", "back24", "back900" }) do
    local p = SOUND_DIR .. n .. ".wav"
    local f = io.open(p, "r")
    if f then io.close(f) wd.snd[n] = p end
  end
  return wd
end

local function update(wd, opts)
  wd.options = opts
end

local function background(wd)
  tick(wd)   -- keeps logging when this screen isn't showing
end

local function refresh(wd, event, touchState)
  tick(wd)
  local fullscreen = event ~= nil              -- EdgeTX only passes events in full screen
  -- full screen gets the whole display, whatever size the widget's normal slot is
  wd.dz = fullscreen and { x = 0, y = 0, w = LCD_W or wd.zone.w, h = LCD_H or wd.zone.h } or wd.zone
  if fullscreen and not wd.fullscreen then scanDays(wd) end
  if not fullscreen and wd.fullscreen then selectDay(wd, 1) end
  wd.fullscreen = fullscreen
  if fullscreen and event ~= 0 then handleEvent(wd, event, touchState) end
  if wd.view then loaderStep(wd.view) end
  if fullscreen then scanStep(wd) end

  if fullscreen or (wd.zone.w >= 300 and wd.zone.h >= 150) then
    drawFull(wd, fullscreen)
  else
    drawCompact(wd)
  end
end

return { name = name, options = options, create = create,
         update = update, refresh = refresh, background = background }
