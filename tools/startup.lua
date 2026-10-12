local INPUT = "top"
local OUTPUT = "left"

local function update()
  local value = redstone.getAnalogInput(INPUT)
  local out

  if value == 0 then
    out = 15
  elseif value >= 14 then
    out = 13
  else
    out = value
  end

  redstone.setAnalogOutput(OUTPUT, out)
end

update()

while true do
  os.pullEvent("redstone")
  update()
end
