--- timed event looper with clock sync capabilities
--
-- An extension of builtin
-- [pattern_time lib](https://monome.org/docs/norns/reference/lib/pattern_time)

local eloop = {}
eloop.__index = eloop

--- constructor
function eloop.new()
  local i = {}
  setmetatable(i, eloop)
  i.rec = 0
  i.play = 0
  i.overdub = 0
  i.prev_time = 0
  i.event = {}
  i.time = {} -- time[i] is time (secs) between i and i+1, or i and end of loop for last event
  i.time_total = 0
  i.count = 0
  i.step = 0
  i.time_factor = 1
  i.sync = false
  i.sync_div = 1 -- beat on which to start/stop recording
  i.time_factor_sync_mult = 1
  i.time_factor_sync_div = 1

  i.metro = metro.init(function() i:next_event() end,1,1)

  -- keep track of running clocks
  i.clocks = {
    syncer = nil,
    rec_stop = nil,
    rec_start = nil,
    play_start = nil
  }

  i.process = function(_) print("event") end

  return i
end

--- clear this pattern
function eloop:clear()
  self.metro:stop()
  self.rec = 0
  self.play = 0
  self.overdub = 0
  self.prev_time = 0
  self.event = {}
  self.time = {}
  self.count = 0
  self.step = 0
  self.time_factor = 1
end

--- adjust the time factor of this pattern.
-- @tparam number f time factor
function eloop:set_time_factor(f)
  self.time_factor = f or 1
end

--- start recording
function eloop:rec_start()
  if not self.sync then
    self.rec = 1
  elseif not self.clocks.rec_start then
    self.clocks.rec_start = clock.run(function()
      clock.sync(self.sync_div)
      self.rec = 1
      self.clocks.rec_start = nil
    end)
  end
end

--- stop recording
function eloop:rec_stop()
  if self.rec == 1 then
    if not self.sync then
      self:_rec_stop()
    elseif not self.clocks.rec_stop then
      self.clocks.rec_stop = clock.run(function()
        clock.sync(self.sync_div)
        self:_rec_stop()
        self.clocks.rec_stop = nil
      end)
    end
  else print("pattern_time: not recording")
  end
end

function eloop:_rec_stop()
  self.rec = 0
  if self.count ~= 0 then
    --print("count "..self.count)
    local t = self.prev_time
    self.prev_time = util.time()
    local elapsed = self.prev_time - t
    self.time[self.count] = elapsed
    self.time_total = self.time_total + elapsed
    --tab.print(self.time)
  else
    print("pattern_time: no events recorded")
  end
end

--- watch
function eloop:watch(e)
  if self.rec == 1 then
    self:rec_event(e)
  elseif self.overdub == 1 then
    self:overdub_event(e)
  end
end

--- record event
function eloop:rec_event(e)
  local c = self.count + 1
  if c == 1 then
    self.prev_time = util.time()
  else
    local t = self.prev_time
    self.prev_time = util.time()
    local elapsed = self.prev_time - t
    self.time[c-1] = elapsed
    self.time_total = self.time_total + elapsed
  end
  self.count = c
  self.event[c] = e
end

--- add overdub event
function eloop:overdub_event(e)
  local c = self.step + 1
  local t = self.prev_time
  self.prev_time = util.time()
  local a = self.time[c-1]
  self.time[c-1] = self.prev_time - t
  table.insert(self.time, c, a - self.time[c-1])
  table.insert(self.event, c, e)
  self.step = self.step + 1
  self.count = self.count + 1
end

--- start the loop
function eloop:start()
  if self.count > 0 then
    if not self.sync then
      self.prev_time = util.time()
      self.process(self.event[1])
      self.play = 1
      self.step = 1
      self.metro.time = self.time[1] * self.time_factor
      self.metro:start()
    else
      self.clocks.syncer = clock.run(self:make_syncer())
    end
  end
end

--- process next event
function eloop:next_event()
  self.prev_time = util.time()
  if self.step == self.count then
    self.step = 1
  else
    self.step = self.step + 1
  end
  self.process(self.event[self.step])
  local tf
  if not self.sync then
    tf = self.time_factor
  else
    tf = self.time_factor_sync_mult / self.time_factor_sync_div
  end
  self.metro.time = self.time[self.step] * tf
  self.metro:start()
end

--- stop this pattern
function eloop:stop()
  if self.play == 1 then
    if not self.sync then
      self.play = 0
      self.overdub = 0
      self.metro:stop()
    else
      -- let pattern finish naturally
      clock.cancel(self.clocks.syncer)
    end
  else print("pattern_time: not playing") end
end

--- set overdub
function eloop:set_overdub(s)
  if s==1 and self.play == 1 and self.rec == 0 then
    self.overdub = 1
  else
    self.overdub = 0
  end
end

-- need to capture reference to self in closure to access self from clock
function eloop:make_syncer()
  return function()
    -- on the beat div
    clock.sync(self.time_total / clock.get_beat_sec())

    -- stop
    self.play = 0
    self.overdub = 0
    self.metro:stop()

    -- then restart
    self.prev_time = util.time()
    self.process(self.event[1])
    self.play = 1
    self.step = 1
    self.metro.time = self.time[1] * self.time_factor
    self.metro:start()
  end
end

return eloop
