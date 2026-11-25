-- Optional runner when no stock Lua is installed: runs a Lua 5.1 test file under lune (Luau) by shimming
-- loadfile / arg / os.exit.
--   lune run addon/GayFurriesLeaderboard/tests/run_lune.luau addon/GayFurriesLeaderboard/tests/test_leaderboard.lua
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local path = process.args[1]
local env = setmetatable({}, { __index = getfenv(1) })
env.arg = { [0] = path }
env.os = { exit = function(c) process.exit(c or 0) end, time = os.time }
env.loadfile = function(p)
  local ok, src = pcall(fs.readFile, p)
  if not ok then return nil, src end
  return luau.load(src, { debugName = p, environment = env })
end
local main = luau.load(fs.readFile(path), { debugName = path, environment = env })
main()
