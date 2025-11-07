local pattern_time = require 'pattern_time'

-- forward 
local psync = {
  stopArm = false
}
psync.__index = psync
setmetatable(psync, {
  __call = function(self, i)
    return self:new(i)
  end
})

function psync:new(i)
  i = i or {}
  setmetatable(i, self)

  i.pattern = pattern_time.new()
  i.pattern.process = self.parse

  return i
end

function psync:parse(e)
  if e.starter == true then
    return
  elseif e.syncer then
    if e.n == 1 and stoparm1 ~= true then
      reset_clock_id1 = clock.run(pattern1_reset_sync)
    elseif e.n == 2 and stoparm2 ~= true then
      reset_clock_id2 = clock.run(pattern2_reset_sync)
    end

    return
  else
    self.process(e)
  end
end

return psync
