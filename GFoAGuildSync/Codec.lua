-- GFoA Guild Sync: pure JSON encoder, base64, CRC32 and the member export string (GFOA1.<crc32>.<base64 JSON>).
-- No game API in here (also loaded by tests/test_logic.lua with a stock Lua 5.1). Uses the `bit` library when the
-- client has it, else plain arithmetic.
local _, ns = ...
ns = ns or {}
local L = ns.logic or {}
ns.logic = L

local floor = math.floor
local byte, char, format = string.byte, string.char, string.format

-- ---------------------------------------------------------------------------
-- JSON (compact, sorted object keys so output is stable)
-- ---------------------------------------------------------------------------

local ARRAY = {}   -- metatable marker: encode this table as a JSON array even when empty

function L.jsonArray(t)
  return setmetatable(t or {}, ARRAY)
end

local function isArray(t)
  if getmetatable(t) == ARRAY then return true end
  local n = #t
  if n == 0 then return false end
  local count = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k > n or k ~= floor(k) then return false end
    count = count + 1
  end
  return count == n
end

local function encodeString(s)
  s = string.gsub(s, '[%c"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == "\\" then return "\\\\" end
    if c == "\n" then return "\\n" end
    if c == "\r" then return "\\r" end
    if c == "\t" then return "\\t" end
    return format("\\u%04x", byte(c))
  end)
  return '"' .. s .. '"'
end

local function encodeNumber(n)
  if n ~= n or n == math.huge or n == -math.huge then return "null" end
  if n == floor(n) and n > -1e15 and n < 1e15 then return format("%.0f", n) end
  return format("%.14g", n)
end

local encode
encode = function(v, out)
  local tv = type(v)
  if tv == "string" then
    out[#out + 1] = encodeString(v)
  elseif tv == "number" then
    out[#out + 1] = encodeNumber(v)
  elseif tv == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif tv == "table" then
    if isArray(v) then
      out[#out + 1] = "["
      for i = 1, #v do
        if i > 1 then out[#out + 1] = "," end
        encode(v[i], out)
      end
      out[#out + 1] = "]"
    else
      local keys = {}
      for k in pairs(v) do
        if type(k) == "string" or type(k) == "number" then keys[#keys + 1] = tostring(k) end
      end
      table.sort(keys)
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        local val = v[k]
        if val == nil then val = v[tonumber(k)] end
        out[#out + 1] = encodeString(k)
        out[#out + 1] = ":"
        encode(val, out)
      end
      out[#out + 1] = "}"
    end
  else
    out[#out + 1] = "null"
  end
end

function L.jsonEncode(v)
  local out = {}
  encode(v, out)
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Base64 (arithmetic only)
-- ---------------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64CHARS = {}
for i = 1, 64 do B64CHARS[i - 1] = string.sub(B64, i, i) end

function L.base64(s)
  local out = {}
  local len = #s
  for i = 1, len, 3 do
    local a, b, c = byte(s, i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local c1 = floor(n / 262144) % 64
    local c2 = floor(n / 4096) % 64
    local c3 = floor(n / 64) % 64
    local c4 = n % 64
    out[#out + 1] = B64CHARS[c1] .. B64CHARS[c2]
      .. (b and B64CHARS[c3] or "=") .. (c and B64CHARS[c4] or "=")
  end
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- CRC32 (IEEE, same as Python zlib.crc32)
-- ---------------------------------------------------------------------------

local TWO32 = 4294967296

local function u32(v)
  v = v % TWO32
  if v < 0 then v = v + TWO32 end
  return v
end

-- Pure arithmetic xor of two unsigned 32-bit numbers.
local function bxorArith(a, b)
  local r, bitv = 0, 1
  for _ = 1, 32 do
    local x, y = a % 2, b % 2
    if x ~= y then r = r + bitv end
    a, b, bitv = (a - x) / 2, (b - y) / 2, bitv * 2
  end
  return r
end

local function pickXor(bitlib)
  if type(bitlib) == "table" and type(bitlib.bxor) == "function" then
    return function(a, b) return u32(bitlib.bxor(a, b)) end
  end
  return bxorArith
end

local tables = {}
local function crcTable(xor)
  if tables[xor] then return tables[xor] end
  local t = {}
  for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
      if c % 2 == 1 then
        c = xor(floor(c / 2), 0xEDB88320)
      else
        c = floor(c / 2)
      end
    end
    t[i] = c
  end
  tables[xor] = t
  return t
end

-- CRC32 of s as an unsigned number. bitlib defaults to the global `bit` (WoW) when present; pass false to force
-- the arithmetic path (tests use both).
function L.crc32(s, bitlib)
  if bitlib == nil then bitlib = rawget(_G, "bit") end
  local xor = pickXor(bitlib)
  local t = crcTable(xor)
  local crc = 0xFFFFFFFF
  for i = 1, #s do
    local idx = xor(crc % 256, byte(s, i))
    crc = xor(floor(crc / 256), t[idx])
  end
  return xor(crc, 0xFFFFFFFF)
end

-- 8 lowercase hex digits without relying on %x for numbers above 2^31.
function L.hex32(v)
  v = u32(v)
  return format("%04x%04x", floor(v / 65536), v % 65536)
end

-- ---------------------------------------------------------------------------
-- Member export string (docs: "Member export string")
-- ---------------------------------------------------------------------------

L.EXPORT_PREFIX = "GFOA1"
L.EXPORT_MAX = 19500
L.EXPORT_PART = 3900
L.EXPORT_MAX_CHARS = 10

local function exportChar(name, c, withRecipes)
  local e = {
    n = name, lvl = c.level, cls = c.class, race = c.race, fac = c.faction, guild = c.guild,
    xp = c.xp, xpMax = c.xpMax,
  }
  if type(c.talents) == "table" then
    local tal = L.jsonArray()
    for _, t in ipairs(c.talents) do
      if type(t) == "table" and t.name then tal[#tal + 1] = L.jsonArray({ t.name, t.points or 0 }) end
    end
    e.tal = tal
  end
  if type(c.professions) == "table" then
    local prof = L.jsonArray()
    for _, p in ipairs(c.professions) do
      if type(p) == "table" and p.name then prof[#prof + 1] = L.jsonArray({ p.name, p.skill or 0, p.max or 0 }) end
    end
    e.prof = prof
  end
  if withRecipes and type(c.recipes) == "table" then
    local rec = {}
    for prof, list in pairs(c.recipes) do
      if type(prof) == "string" and type(list) == "table" then
        local names = L.jsonArray()
        for _, r in ipairs(list) do
          if type(r) == "string" then names[#names + 1] = r end
        end
        rec[prof] = names
      end
    end
    e.rec = rec
  end
  return e
end

-- Link codes (docs "Link codes"): 6 characters from an alphabet without look-alikes (no 0/O, 1/I/L).
L.LINK_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
L.LINK_LENGTH = 6

-- Normalises a typed code (case, spaces, dashes). Returns the code, or nil when it isn't one.
function L.normalizeLinkCode(raw)
  if type(raw) ~= "string" then return nil end
  local code = string.upper(string.sub(string.gsub(raw, "[%s%-]", ""), 1, 16))
  if #code ~= L.LINK_LENGTH or not string.match(code, "^[" .. L.LINK_ALPHABET .. "]+$") then return nil end
  return code
end

-- A main character name as sent in the payload: a non-empty string of at most 48 bytes, else nil.
function L.cleanMainName(raw)
  if type(raw) ~= "string" then return nil end
  local name = string.match(raw, "^%s*(.-)%s*$")
  if name == "" or #name > 48 then return nil end
  return name
end

-- The JSON payload table for up to 10 own characters (most recently updated first). `extra` (optional) adds the
-- account's link code and chosen main as top-level `link` / `main` when they're set and valid.
function L.exportPayload(characters, now, realm, addonVersion, withRecipes, extra)
  local names = {}
  for name, c in pairs(characters or {}) do
    if type(name) == "string" and type(c) == "table" then names[#names + 1] = name end
  end
  table.sort(names, function(a, b)
    local ua, ub = characters[a].updated or 0, characters[b].updated or 0
    if ua ~= ub then return ua > ub end
    return a < b
  end)
  local chars = L.jsonArray()
  for i = 1, math.min(L.EXPORT_MAX_CHARS, #names) do
    chars[#chars + 1] = exportChar(names[i], characters[names[i]], withRecipes)
  end
  local payload = { v = 1, t = now, realm = realm, addon = addonVersion, chars = chars }
  if type(extra) == "table" then
    payload.link = L.normalizeLinkCode(extra.link)
    payload.main = L.cleanMainName(extra.main)
  end
  return payload
end

function L.encodeExport(payload)
  local b64 = L.base64(L.jsonEncode(payload))
  return L.EXPORT_PREFIX .. "." .. L.hex32(L.crc32(b64)) .. "." .. b64
end

-- Returns exportString, droppedRecipes; or nil, reason when even without recipes it's too long / empty.
function L.makeExport(characters, now, realm, addonVersion, extra)
  local payload = L.exportPayload(characters, now, realm, addonVersion, true, extra)
  if #payload.chars == 0 then return nil, "no characters saved yet" end
  local s = L.encodeExport(payload)
  if #s <= L.EXPORT_MAX then return s, false end
  s = L.encodeExport(L.exportPayload(characters, now, realm, addonVersion, false, extra))
  if #s <= L.EXPORT_MAX then return s, true end
  return nil, "too long even without recipes"
end

-- Splits s into parts of at most size characters.
function L.splitParts(s, size)
  size = size or L.EXPORT_PART
  local parts = {}
  for i = 1, #s, size do parts[#parts + 1] = string.sub(s, i, i + size - 1) end
  if #parts == 0 then parts[1] = "" end
  return parts
end

-- ---------------------------------------------------------------------------
-- Decoding (used by officer-mode addons to check guild sync payloads)
-- ---------------------------------------------------------------------------

local B64INDEX = {}
for i = 1, 64 do B64INDEX[byte(B64, i)] = i - 1 end

-- Returns the decoded string, or nil for invalid input.
function L.base64Decode(s)
  if type(s) ~= "string" or #s % 4 ~= 0 then return nil end
  local out = {}
  for i = 1, #s, 4 do
    local a, b, c, d = byte(s, i, i + 3)
    local va, vb = B64INDEX[a], B64INDEX[b]
    if not va or not vb then return nil end
    local pad3, pad4 = c == 61, d == 61   -- "="
    local vc, vd = B64INDEX[c], B64INDEX[d]
    if (not vc and not pad3) or (not vd and not pad4) or (pad3 and not pad4) then return nil end
    if (pad3 or pad4) and i + 3 ~= #s then return nil end
    local n = va * 262144 + vb * 4096 + (vc or 0) * 64 + (vd or 0)
    local x, y, z = floor(n / 65536), floor(n / 256) % 256, n % 256
    if pad3 then
      out[#out + 1] = char(x)
    elseif pad4 then
      out[#out + 1] = char(x, y)
    else
      out[#out + 1] = char(x, y, z)
    end
  end
  return table.concat(out)
end

-- Minimal JSON decoder (objects, arrays, strings with \uXXXX up to U+FFFF, numbers, true/false/null).
-- Arrays come back marked with L.jsonArray so they re-encode as arrays even when empty. Returns value or nil, err.
function L.jsonDecode(s)
  if type(s) ~= "string" then return nil, "not a string" end
  local pos = 1
  local function ws()
    pos = string.find(s, "[^ \t\r\n]", pos) or (#s + 1)
  end
  local value
  local function str()
    pos = pos + 1   -- opening quote
    local out = {}
    while true do
      local c = string.sub(s, pos, pos)
      if c == "" then error("unterminated string") end
      if c == '"' then
        pos = pos + 1
        return table.concat(out)
      end
      if c == "\\" then
        local e = string.sub(s, pos + 1, pos + 1)
        local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
        if map[e] then
          out[#out + 1] = map[e]
          pos = pos + 2
        elseif e == "u" then
          local h = tonumber(string.sub(s, pos + 2, pos + 5), 16)
          if not h then error("bad \\u escape") end
          if h < 0x80 then
            out[#out + 1] = char(h)
          elseif h < 0x800 then
            out[#out + 1] = char(0xC0 + floor(h / 64), 0x80 + h % 64)
          else
            out[#out + 1] = char(0xE0 + floor(h / 4096), 0x80 + floor(h / 64) % 64, 0x80 + h % 64)
          end
          pos = pos + 6
        else
          error("bad escape")
        end
      else
        local stop = string.find(s, '["\\]', pos) or (#s + 1)
        out[#out + 1] = string.sub(s, pos, stop - 1)
        pos = stop
      end
    end
  end
  value = function()
    ws()
    local c = string.sub(s, pos, pos)
    if c == "{" then
      pos = pos + 1
      local obj = {}
      ws()
      if string.sub(s, pos, pos) == "}" then
        pos = pos + 1
        return obj
      end
      while true do
        ws()
        if string.sub(s, pos, pos) ~= '"' then error("expected key") end
        local k = str()
        ws()
        if string.sub(s, pos, pos) ~= ":" then error("expected :") end
        pos = pos + 1
        obj[k] = value()
        ws()
        local d = string.sub(s, pos, pos)
        pos = pos + 1
        if d == "}" then return obj end
        if d ~= "," then error("expected , or }") end
      end
    elseif c == "[" then
      pos = pos + 1
      local arr = L.jsonArray()
      ws()
      if string.sub(s, pos, pos) == "]" then
        pos = pos + 1
        return arr
      end
      while true do
        arr[#arr + 1] = value()
        ws()
        local d = string.sub(s, pos, pos)
        pos = pos + 1
        if d == "]" then return arr end
        if d ~= "," then error("expected , or ]") end
      end
    elseif c == '"' then
      return str()
    elseif string.sub(s, pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif string.sub(s, pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif string.sub(s, pos, pos + 3) == "null" then
      pos = pos + 4
      return nil
    else
      local num = string.match(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      if not num or num == "" then error("unexpected character at " .. pos) end
      pos = pos + #num
      local n = tonumber(num)
      if not n then error("bad number") end
      return n
    end
  end
  local ok, result = pcall(function()
    local v = value()
    ws()
    if pos <= #s then error("trailing data") end
    return v
  end)
  if not ok then return nil, tostring(result) end
  return result
end

-- Checks prefix and CRC of an export string; returns the decoded payload table or nil, reason.
function L.decodeExport(s)
  if type(s) ~= "string" then return nil, "not a string" end
  local prefix, crc, b64 = string.match(s, "^(%w+)%.(%x+)%.([%w%+/=]+)$")
  if prefix ~= L.EXPORT_PREFIX then return nil, "unknown prefix" end
  if string.lower(crc) ~= L.hex32(L.crc32(b64)) then return nil, "bad crc" end
  local json = L.base64Decode(b64)
  if not json then return nil, "bad base64" end
  local payload, err = L.jsonDecode(json)
  if type(payload) ~= "table" then return nil, "bad json: " .. tostring(err) end
  return payload
end

-- Keeps only characters whose n is the sender (realm stripped). Returns the payload and how many were kept.
function L.filterSender(payload, sender)
  local short = L.stripRealm and L.stripRealm(sender) or sender
  local kept = L.jsonArray()
  for _, c in ipairs(type(payload.chars) == "table" and payload.chars or {}) do
    if type(c) == "table" and type(c.n) == "string" and short and string.lower(c.n) == string.lower(short) then
      kept[#kept + 1] = c
    end
  end
  payload.chars = kept
  return payload, #kept
end

-- ---------------------------------------------------------------------------
-- Guild addon sync framing: D:<msgId>:<i>/<n>:<chunk>, H, A:<msgId>
-- ---------------------------------------------------------------------------

L.COMM_PREFIX = "GFOA"
L.COMM_MAX_BYTES = 254   -- "under 255 bytes per message"

local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"

-- 4 base36 characters. rand(n) returns an integer 1..n (math.random in game).
function L.messageId(rand)
  rand = rand or math.random
  local out = {}
  for i = 1, 4 do
    local k = rand(36)
    out[i] = string.sub(B36, k, k)
  end
  return table.concat(out)
end

-- Splits data into addon messages, each at most maxBytes long.
function L.chunkMessages(data, msgId, maxBytes)
  maxBytes = maxBytes or L.COMM_MAX_BYTES
  local n = 1
  local size
  for _ = 1, 10 do
    local header = #("D:" .. msgId .. ":" .. n .. "/" .. n .. ":")
    size = maxBytes - header
    local needed = math.max(1, math.ceil(#data / size))
    if needed == n then break end
    n = needed
  end
  local out = {}
  for i = 1, n do
    out[i] = "D:" .. msgId .. ":" .. i .. "/" .. n .. ":" .. string.sub(data, (i - 1) * size + 1, i * size)
  end
  return out
end

-- Returns kind ("H", "A", "D", "R") and fields, or nil for anything else.
function L.parseMessage(msg)
  if type(msg) ~= "string" then return nil end
  if msg == "H" then return "H" end
  local ack = string.match(msg, "^A:(%w+)$")
  if ack then return "A", ack end
  -- Craft request (explicit click by the sender): R:<msgId>:<itemId>:<item name>
  local rid, itemId, item = string.match(msg, "^R:(%w+):(%d+):(.+)$")
  if rid then return "R", rid, tonumber(itemId), item end
  local id, i, n, chunk = string.match(msg, "^D:(%w+):(%d+)/(%d+):(.*)$")
  if id then
    i, n = tonumber(i), tonumber(n)
    if i and n and i >= 1 and i <= n and n <= 500 then return "D", id, i, n, chunk end
  end
  return nil
end

-- Adds a chunk to pending[key]. Returns the full data string once all n chunks are in (and clears the entry).
function L.addChunk(pending, key, i, n, chunk, now)
  local p = pending[key]
  if not p or p.n ~= n then
    p = { n = n, parts = {}, have = 0, t = now }
    pending[key] = p
  end
  if not p.parts[i] then
    p.parts[i] = chunk
    p.have = p.have + 1
  end
  p.t = now
  if p.have < n then return nil end
  pending[key] = nil
  return table.concat(p.parts, "", 1, n)
end

-- Drops incomplete sets not touched for maxAge seconds (60 per the format).
function L.expirePending(pending, now, maxAge)
  for k, p in pairs(pending) do
    if now - (p.t or 0) > (maxAge or 60) then pending[k] = nil end
  end
end

-- Drops guildSync entries older than cutoff.
function L.pruneGuildSync(map, cutoff)
  if type(map) ~= "table" then return end
  for k, e in pairs(map) do
    if type(e) ~= "table" or (e.t or 0) < cutoff then map[k] = nil end
  end
end

-- ---------------------------------------------------------------------------
-- 1.2.0 messages: R (craft request, docs "Craft requests over guild sync"), C (my cooldowns), Q (cooldown query)
--   R:<msgId>:<itemId>:<item name, max 60 chars>   member -> officer addons, acked with A:<msgId>
--   C:<name>=<seconds left>;<name>=<seconds left>   any addon -> guild, own logged-in character only, 0 = ready
--   Q                                               "who has cooldowns?" (sent only when someone opens the window)
-- Older addons ignore kinds they don't know.
-- ---------------------------------------------------------------------------

L.ITEM_NAME_MAX = 60

-- Cuts s to at most max bytes without splitting a UTF-8 character.
function L.utf8Cut(s, max)
  if type(s) ~= "string" or #s <= max then return s end
  local cut = max
  -- step back over continuation bytes (10xxxxxx) so the next character starts at cut + 1
  while cut > 0 do
    local b = byte(s, cut + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end
    cut = cut - 1
  end
  return string.sub(s, 1, cut)
end

function L.craftRequestMessage(msgId, itemId, item)
  local name = string.gsub(tostring(item or ""), "[\r\n]", " ")
  return "R:" .. msgId .. ":" .. tostring(math.floor(tonumber(itemId) or 0)) .. ":" .. L.utf8Cut(name, L.ITEM_NAME_MAX)
end

-- Encodes { { name, readyAt } } as a C message (at most maxBytes, whole entries only). now: current time.
-- version (1.2.1+): the sender's addon version as a leading "@1.2.1" entry; older addons skip it (no "=").
function L.cooldownMessage(list, now, maxBytes, version)
  maxBytes = maxBytes or L.COMM_MAX_BYTES
  local msg = "C:"
  local first = true
  if L.parseVersion(version) then
    msg = msg .. "@" .. version
    first = false
  end
  for _, e in ipairs(list or {}) do
    if type(e.name) == "string" and not string.find(e.name, "[;=\r\n]") then
      local left = (e.readyAt or 0) - now
      if left < 0 then left = 0 end
      local part = (first and "" or ";") .. e.name .. "=" .. math.floor(left)
      if #msg + #part > maxBytes then break end
      msg = msg .. part
      first = false
    end
  end
  return msg
end

-- Parses the body of a C message into { { name, readyAt } } using the receiver's clock.
function L.parseCooldowns(body, now)
  local out = {}
  for part in string.gmatch(body or "", "[^;]+") do
    local name, left = string.match(part, "^(.-)=(%d+)$")
    if name and name ~= "" then
      local secs = tonumber(left)
      table.insert(out, { name = name, readyAt = secs > 0 and (now + secs) or 0 })
    end
  end
  return out
end

-- The sender's addon version from a C message body ("@1.2.1;..."), or nil.
function L.cooldownVersion(body)
  local v = string.match(type(body) == "string" and body or "", "^@([^;]*)")
  if L.parseVersion(v) then return v end
  return nil
end

local baseParse = L.parseMessage
function L.parseMessage(msg)
  local kind, a, b, c, d = baseParse(msg)
  if kind then return kind, a, b, c, d end
  if type(msg) ~= "string" then return nil end
  if msg == "Q" then return "Q" end
  local id, itemId, item = string.match(msg, "^R:(%w+):(%d+):(.+)$")
  if id then return "R", id, tonumber(itemId), item end
  local body = string.match(msg, "^C:(.*)$")
  if body then return "C", body end
  return nil
end

-- Officer side: adds a request to db.craftRequests unless the same sender asked for the same item the same day.
-- Returns true when added.
function L.addCraftRequest(list, req)
  if type(list) ~= "table" or type(req) ~= "table" or not req.sender or not req.itemId then return false end
  local day = math.floor((req.t or 0) / 86400)
  for _, r in ipairs(list) do
    if type(r) == "table" and r.sender == req.sender and r.itemId == req.itemId
        and math.floor((r.t or 0) / 86400) == day then
      return false
    end
  end
  table.insert(list, { t = req.t, sender = req.sender, itemId = req.itemId, item = req.item })
  return true
end

return L
