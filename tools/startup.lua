local INPUT = "top"
local OUTPUT = "left"
local LOG_FILE = "redstone.log"
local MAX_LOG_SIZE = 50000

local lastIn = nil
local lastOut = nil

local function log(message)
  local line = os.date("%H:%M:%S") .. "  " .. message
  print(line)

  if fs.exists(LOG_FILE) and fs.getSize(LOG_FILE) > MAX_LOG_SIZE then
    fs.delete(LOG_FILE)
  end

  local file = fs.open(LOG_FILE, "a")
  file.writeLine(line)
  file.close()
end

local function pickOutput(value)
  if value == 0 then
    return 15, "input off, full power"
  elseif value >= 14 then
    return 13, "input too high, capped"
  else
    return value, "pass through"
  end
end

local function update()
  local value = redstone.getAnalogInput(INPUT)
  local out, reason = pickOutput(value)

  if value ~= lastIn or out ~= lastOut then
    redstone.setAnalogOutput(OUTPUT, out)
    log("IN " .. value .. "  ->  OUT " .. out .. "  (" .. reason .. ")")
    lastIn = value
    lastOut = out
  end
end

term.clear()
term.setCursorPos(1, 1)
log("Boot: controller started")
update()

while true do
  os.pullEvent("redstone")
  update()
end
