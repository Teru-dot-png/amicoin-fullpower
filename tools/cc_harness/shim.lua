-- tools/cc_harness/shim.lua
-- Minimal CC:Tweaked API shim so the Opus UI code can run under native Lua 5.4.
-- Provides term/device with a virtual screen buffer, fs, os (timers + event
-- queue), colors, keys, parallel, textutils, peripheral, http, device.
-- Returns a table of helpers (screen dump, event injection).

local M = {}

----------------------------------------------------------------------
-- colors / keys
----------------------------------------------------------------------
local colors = {}
local colorNames = {
  white=1, orange=2, magenta=4, lightBlue=8, yellow=16, lime=32, pink=64,
  gray=128, grey=128, lightGray=256, lightGrey=256, cyan=512, purple=1024,
  blue=2048, brown=4096, green=8192, red=16384, black=32768,
}
for k,v in pairs(colorNames) do colors[k]=v end
colors.combine = function(...) local r=0; for _,c in ipairs({...}) do r=r|c end; return r end
colors.toBlit = function(c)
  local n = math.floor(math.log(c,2)+0.5)
  return string.format("%x", n)
end
_G.colors = colors
_G.colours = colors

local keys = setmetatable({}, {__index=function(_,k) return 0 end})
keys.leftCtrl=341; keys.rightCtrl=345; keys.leftAlt=342; keys.rightAlt=346
keys.leftShift=340; keys.rightShift=344; keys.enter=257; keys.tab=258
keys.u=85; keys.p=80; keys.t=84; keys.a=65
keys.getName = function(c) return "key"..tostring(c) end
_G.keys = keys

----------------------------------------------------------------------
-- Virtual screen buffer + term/device
----------------------------------------------------------------------
local W, H = 51, 19
local screen = { text={}, fg={}, bg={} }
local function blankScreen()
  for y=1,H do
    screen.text[y] = string.rep(" ", W)
    screen.fg[y]   = string.rep("0", W)
    screen.bg[y]   = string.rep("f", W)
  end
end
blankScreen()

local curX, curY, curFg, curBg = 1, 1, 1, colors.black
local blink = false

local function clampWrite(x, y, text, fg, bg)
  if y < 1 or y > H then return end
  if x > W then return end
  local len = #text
  if x < 1 then
    text = text:sub(2-x); if fg then fg=fg:sub(2-x) end; if bg then bg=bg:sub(2-x) end
    len = #text; x = 1
  end
  if x + len - 1 > W then
    text = text:sub(1, W-x+1)
    if fg then fg=fg:sub(1, W-x+1) end
    if bg then bg=bg:sub(1, W-x+1) end
    len = #text
  end
  if len <= 0 then return end
  local function splice(s, pos, repl)
    return s:sub(1,pos-1) .. repl .. s:sub(pos+#repl)
  end
  screen.text[y] = splice(screen.text[y], x, text)
  if fg then screen.fg[y] = splice(screen.fg[y], x, fg) end
  if bg then screen.bg[y] = splice(screen.bg[y], x, bg) end
end

local term = {}
term.getSize = function() return W, H end
term.isColor = function() return true end
term.isColour = function() return true end
term.setCursorPos = function(x,y) curX,curY = x,y end
term.getCursorPos = function() return curX, curY end
term.setCursorBlink = function(b) blink = b end
term.setTextColor = function(c) curFg = c end
term.setTextColour = term.setTextColor
term.setBackgroundColor = function(c) curBg = c end
term.setBackgroundColour = term.setBackgroundColor
term.getTextColor = function() return curFg end
term.getBackgroundColor = function() return curBg end
term.setTextScale = function() end
term.clear = function()
  blankScreen()
end
term.clearLine = function()
  if curY>=1 and curY<=H then
    screen.text[curY]=string.rep(" ",W)
    screen.bg[curY]=string.rep(colors.toBlit(curBg),W)
  end
end
term.write = function(t)
  t = tostring(t)
  clampWrite(curX, curY, t,
    string.rep(colors.toBlit(curFg), #t),
    string.rep(colors.toBlit(curBg), #t))
  curX = curX + #t
end
term.blit = function(t, fg, bg)
  clampWrite(curX, curY, t, fg, bg)
  curX = curX + #t
end
term.scroll = function() end
term.current = function() return term end
term.native = function() return term end
term.redirect = function() return term end
_G.term = term

-- device table (Opus references device[side])
_G.device = setmetatable({}, {__index=function() return nil end})

----------------------------------------------------------------------
-- os: timers + scripted event queue
----------------------------------------------------------------------
local realos = os
local startClock = realos.clock()
local nextTimer = 0
local pendingTimers = {}   -- id -> true (fires as 'timer' on next pullEvent)
local eventQueue = {}      -- injected events
local cc_os = {}
cc_os.clock = function() return realos.clock() - startClock end
cc_os.time = function() return 0 end
cc_os.epoch = function() return math.floor(realos.clock()*1000) end
cc_os.day = function() return 0 end
cc_os.startTimer = function(_) nextTimer = nextTimer + 1; pendingTimers[nextTimer]=true; return nextTimer end
cc_os.cancelTimer = function(id) pendingTimers[id]=nil end
cc_os.sleep = function(_) M.yields = (M.yields or 0) + 1 end  -- no-op; counts yields
cc_os.queueEvent = function(name, ...) eventQueue[#eventQueue+1] = {name, ...} end
cc_os.getComputerID = function() return 0 end
cc_os.getComputerLabel = function() return "test" end
cc_os.reboot = function() error("REBOOT called") end
cc_os.shutdown = function() error("SHUTDOWN called") end
cc_os.version = function() return "CraftOS 1.8 (shim)" end
local function nextEvent()
  if #eventQueue > 0 then return table.remove(eventQueue, 1) end
  -- fire a pending timer if any
  local id = next(pendingTimers)
  if id then pendingTimers[id]=nil; return {"timer", id} end
  return {"terminate"}
end
cc_os.pullEventRaw = function(filter)
  while true do
    local e = nextEvent()
    if not filter or e[1]==filter or e[1]=="terminate" then
      return table.unpack(e)
    end
  end
end
cc_os.pullEvent = function(filter)
  local e = {cc_os.pullEventRaw(filter)}
  if e[1]=="terminate" then error("Terminated", 0) end
  return table.unpack(e)
end
-- keep native bits
cc_os.run = function() return true end
cc_os.loadAPI = function() return true end
_G.os = setmetatable(cc_os, {__index=realos})

----------------------------------------------------------------------
-- fs (in-memory + read-through to real repo for require)
----------------------------------------------------------------------
local fs = {}
fs.exists = function(p) local f=io.open(p:gsub("^/",""), "r"); if f then f:close(); return true end; return false end
fs.open = function(p, mode)
  p = p:gsub("^/","")
  if mode:find("r") then
    local f=io.open(p,"r"); if not f then return nil end
    local data=f:read("*a"); f:close()
    local pos=1
    return { readAll=function() return data end,
             readLine=function() return nil end,
             read=function() return nil end,
             close=function() end }
  else
    local f=io.open(p,"w")
    return { write=function(_,s) if s==nil then else f:write(s) end end,
             writeLine=function(_,s) f:write((s or "").."\n") end,
             close=function() f:close() end }
  end
end
fs.list = function(p)
  p = p:gsub("^/","")
  local t={}; local h=io.popen('ls "'..p..'" 2>/dev/null')
  if h then for l in h:lines() do t[#t+1]=l end; h:close() end
  return t
end
fs.makeDir = function() end
fs.delete = function() end
fs.getDir = function(p) return (p:gsub("/[^/]*$","")) end
fs.getName = function(p) return (p:gsub(".*/","")) end
fs.combine = function(a,b) return (a.."/"..b):gsub("//","/") end
fs.getSize = function() return 0 end
fs.getFreeSpace = function() return 1000000 end
fs.isDir = function(p) local h=io.popen('test -d "'..p:gsub("^/","")..'" && echo y'); local r=h:read("*a"); h:close(); return r:find("y")~=nil end
_G.fs = fs

----------------------------------------------------------------------
-- textutils, peripheral, http, parallel, read
----------------------------------------------------------------------
_G.textutils = {
  serialize = function(t) return tostring(t) end,
  serialise = function(t) return tostring(t) end,
  unserialize = function() return nil end,
  unserialise = function() return nil end,
  serializeJSON = function() return "{}" end,
  serialiseJSON = function() return "{}" end,
}
_G.peripheral = {
  find=function() return nil end, wrap=function() return nil end,
  getType=function() return nil end, getNames=function() return {} end,
  isPresent=function() return false end,
}
_G.http = { get=function() return nil end, post=function() return nil end }
_G.read = function() return "" end

-- parallel: cooperative via coroutines. waitForAny returns when first finishes;
-- waitForAll when all finish. Our harness only needs them not to be required for
-- UI init, but provide a working impl with an iteration cap.
local function makeParallel(waitAll)
  return function(...)
    local fns = {...}
    local cos = {}
    for i,f in ipairs(fns) do cos[i]=coroutine.create(f) end
    local done = 0
    local guard = 0
    while true do
      guard = guard + 1
      if guard > 100000 then error("parallel guard tripped") end
      local alive = false
      for i,co in ipairs(cos) do
        if co and coroutine.status(co) ~= "dead" then
          alive = true
          local ok, err = coroutine.resume(co)
          if not ok then error(err) end
          if coroutine.status(co)=="dead" then
            cos[i]=false; done=done+1
            if not waitAll then return end
          end
        end
      end
      if not alive then return end
      if waitAll and done>=#fns then return end
    end
  end
end
_G.parallel = { waitForAll=makeParallel(true), waitForAny=makeParallel(false) }

----------------------------------------------------------------------
-- require: dotted module names -> repo files
----------------------------------------------------------------------
local realLoadfile = loadfile
-- Opus loadComponents() calls loadfile('/ami/lib/ui/components/X.lua', 't', env)
-- Map the absolute CC path to a repo-relative one and honor the custom env.
_G.loadfile = function(path, mode, env)
  local p = path
  if type(p)=="string" then p = p:gsub("^/","") end
  if env ~= nil then
    return realLoadfile(p, mode, env)
  elseif mode ~= nil then
    return realLoadfile(p, mode)
  end
  return realLoadfile(p)
end

local moduleCache = {}
local searchRoots = { "", "node/", "ami/" }
local function resolve(name)
  local rel = name:gsub("%.", "/") .. ".lua"
  -- direct
  local candidates = { rel }
  if not name:find("%.") then
    candidates[#candidates+1] = "node/"..rel
  end
  for _,c in ipairs(candidates) do
    local f=io.open(c,"r"); if f then f:close(); return c end
  end
  return nil
end
_G.require = function(name)
  if moduleCache[name] ~= nil then return moduleCache[name] end
  local path = resolve(name)
  if not path then error("module not found: "..name) end
  local chunk, err = loadfile(path)
  if not chunk then error("loadfile "..path..": "..tostring(err)) end
  moduleCache[name] = true -- guard against cycles
  local res = chunk()
  moduleCache[name] = res
  return res
end

----------------------------------------------------------------------
-- helpers exposed to the test driver
----------------------------------------------------------------------
M.W, M.H = W, H
M.term = term
M.screen = screen
M.injectEvent = function(...) eventQueue[#eventQueue+1] = {...} end
M.dumpScreen = function()
  local out = {}
  out[#out+1] = "+" .. string.rep("-", W) .. "+"
  for y=1,H do out[#out+1] = "|" .. screen.text[y] .. "|" end
  out[#out+1] = "+" .. string.rep("-", W) .. "+"
  return table.concat(out, "\n")
end
M.colors = colors
return M
