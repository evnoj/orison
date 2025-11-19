--- timed event looper with clock sync capabilities
--
-- An extension of the builtin
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
  i.sync_offset = 0
  i.sync_div = 1 -- beat on which to start/stop recording
  i.resync = false -- means when reaching end of loop, need to remake clock syncer
  i.sync_stop = false -- if true, calling stop() on a clock-synced pattern will let it run out before stopping. if false, stops immediately
  -- don't set directly, use set_time_factor_sync methods
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

  -- callbacks to do things, mainly for when synced
  i.callbacks = {
    -- after record start
    rec_start = function() end,
    -- before record stop, only if anything was recorded
    rec_stop_pre = function() end,
    -- after record stop, whether anything was recorded or not
    rec_stop_post = function() end,
    start = function() end,
    stop = function() end,
    loop = function() end, -- called at the end of a loop
  }

  i.process = function(_) print("event") end

  return i
end

local function round(n)
  return math.floor(0.5 + n)
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
  self.time_total = 0
  self.count = 0
  self.step = 0
  self.time_factor = 1
  self.time_factor_sync_mult = 1
  self.time_factor_sync_div = 1
end

--- adjust the time factor of this pattern.
-- @tparam number f time factor
function eloop:set_time_factor(f)
  self.time_factor = f or 1
end

function eloop:set_time_factor_sync_mult(i)
  if i ~= math.floor(i) then
    error("Time factor synced multiplier must be an integer")
  end

  self.time_factor_sync_mult = i

  if self.clocks.syncer then
    clock.cancel(self.clocks.syncer)
    self.resync = true
  end
end

function eloop:set_time_factor_sync_div(i)
  if i ~= math.floor(i) then
    error("Time factor synced divider must be an integer, i:"..i..", math.floor(i):"..math.floor(i))
  end

  self.time_factor_sync_div = i

  if self.clocks.syncer then
    clock.cancel(self.clocks.syncer)
    self.resync = true
  end
end

function eloop:set_time_factor(f)
  self.time_factor = f or 1
end

--- start recording
function eloop:rec_start()
  if not self.sync then
    self:_rec_start()
  elseif not self.clocks.rec_start then
    self.clocks.rec_start = clock.run(function()
      clock.sync(self.sync_div)
      self:_rec_start()
      self:watch({_marker = true})
      self.clocks.rec_start = nil
    end)
  end
end

function eloop:_rec_start()
  self.rec = 1
  self.callbacks.rec_start()
end

--- stop recording
function eloop:rec_stop()
  if self.rec == 1 then
    if not self.sync then
      self:_rec_stop()
    elseif not self.clocks.rec_stop then
      self.clocks.rec_stop = clock.run(function()
        clock.sync(self.sync_div)

        self:watch({_marker = true})

        local time_of_div = clock.get_beat_sec() * self.sync_div
        local num_of_div = round(self.time_total / time_of_div)
        self.beat_len = num_of_div * self.sync_div

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
    self.callbacks.rec_stop_pre()
    local t = self.prev_time
    self.prev_time = util.time()
    local elapsed = self.prev_time - t
    self.time[self.count] = elapsed
    self.time_total = self.time_total + elapsed
  else
    print("pattern_time: no events recorded")
  end

  self.callbacks.rec_stop_post()
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

function eloop:update_offset()
  local current_beat = clock.get_beats()
  self.sync_offset = current_beat %
    (self.time_factor_sync_mult/self.time_factor_sync_div * self.beat_len)
end
--- start the loop
function eloop:start()
  if self.count > 0 then
    self.prev_time = util.time()
    self:_process(self.event[1])
    self.play = 1
    self.step = 1

    if self.sync then
      self.metro.time = self.time[1] * self.time_factor_sync_mult / self.time_factor_sync_div
    else
      self.metro.time = self.time[1] * self.time_factor
    end
    self.metro:start()

    self.callbacks.start()

    if self.sync then
      self:update_offset()
      self.clocks.syncer = clock.run(self:make_syncer())
    end
  end
end

--- stop this pattern
function eloop:stop()
  if self.play ~= 1 then
    print("pattern_time: not playing")
    return
  end

  if not self.sync then
    self.play = 0
    self.overdub = 0
    self.metro:stop()
    self.callbacks.stop()

    if self.clocks.syncer then
      clock.cancel(self.clocks.syncer)
      self.clocks.syncer = nil
    end
  elseif self.clocks.syncer then
    if self.sync_stop then
      -- wait for the stop to finish naturally
      self.clocks.syncer = nil
    else
      clock.cancel(self.clocks.syncer)
      self.clocks.syncer = nil
      self.play = 0
      self.overdub = 0
      self.metro:stop()
      self.callbacks.stop()
    end
  end
end

--- process next event
function eloop:next_event()
  self.prev_time = util.time()
  if self.step == self.count then
    self.step = 1

    if self.resync then
      self.resync = false

      if not self.clocks.syncer then -- means we're stopping
        self.callbacks.stop()
        return
      else
        self:update_offset()
        self.clocks.syncer = clock.run(self:make_syncer())
      end
    end
  else
    self.step = self.step + 1
  end
  self:_process(self.event[self.step])
  local tf
  if not self.sync then
    tf = self.time_factor
  else
    tf = self.time_factor_sync_mult / self.time_factor_sync_div
  end
  self.metro.time = self.time[self.step] * tf
  self.metro:start()
end

--- set overdub
function eloop:set_overdub(s)
  if s==1 and self.play == 1 and self.rec == 0 then
    self.overdub = 1
  else
    self.overdub = 0
  end
end

function eloop:_process(e)
  if not e._marker then -- marker events are only for timing synchronization
    self.process(e)
  end
end

-- need to capture reference to self in closure to access self from clock
function eloop:make_syncer()
  return function()
    while true do
      clock.sync(self.time_factor_sync_mult/self.time_factor_sync_div * self.beat_len,
        self.sync_offset)

      -- stop
      self.play = 0
      self.overdub = 0
      self.metro:stop()

      -- if not restarting, perform stop callback
      if not self.clocks.syncer then
        self.callbacks.stop()
        break
      else
        self.callbacks.loop()
      end

      -- then restart
      self.prev_time = util.time()
      self:_process(self.event[1])
      self.play = 1
      self.step = 1
      self.metro.time = self.time[1] * self.time_factor_sync_mult / self.time_factor_sync_div
      self.metro:start()
    end
  end
end

return eloop
