-- declaratively assign actions to different types of key presses

local keyhelper = {}
keyhelper.__index = keyhelper

local _key = {}
_key.__index = _key

local threshold = 0.5 -- time in seconds that denotes short vs long press

function _key.new(x, y)
  local t = {}
  setmetatable(t, _key)

  t.x = x
  t.y = y

  return t
end

-- each arg is a dimension, with the value being the size of the dimension
-- ex. keyhelper.new(16, 8) creates a key helper with keys matching the dimensions of a 128 grid
-- can just include x_size for one dimension, ex. keyhelper.new(3) for the norns keys
function keyhelper.new(x_size, y_size)
  local keys = {}
  setmetatable(keys, keyhelper)

  if y_size then -- 2d array
    for i=1,x_size do
      keys[i] = {}
      for j=1,y_size do
        keys[i][j] = _key.new(i, j)
      end
    end
  else -- 1d array
    for i=1,x_size do
      keys[i] = _key.new(i)
    end
  end

  return keys
end

-- actions to support callbacks for
-- press(x, y, z): on key press down
-- release(x, y, z): on key release
-- short_press(x, y): on key release shortly after a press
-- long_press_start(x, y): detected a long press (held 0.5 seconds)
-- long_press_release(x, y): released a long press

-- z comes first, to enable leaving off y if using single-dimensional button array
-- ex. keyhelper:handle(z, k) for norns keys
function keyhelper:handle(z, x, y)
  local key
  if y then
    key = self[x][y]
  else
    key = self[x]
  end

  if z == 1 then
    key.z = 1
    key.pressed = true

    if key.short_press then
      key.press_time = util.time()
    end

    if key.press then key.press(x, y) end

    if key.long_press_start or key.long_press_release then
      key.long_press_metro = metro.init(function()
        key.long_press_active = true
        key.press_time = nil -- not a short press
        if key.long_press_start then key.long_press_start(x, y) end
      end, threshold, 1)
    end
  elseif z == 0 then
    key.z = 0
    key.pressed = false
    if key.release then key.release(x, y) end

    if key.short_press and key.press_time then
      if util.time() - key.press_time < threshold then
        key.short_press(x, y)
      end
    end

    if key.long_press_metro then
      key.long_press_metro:stop()
      metro.free(key.long_press_metro.id)
      key.long_press_metro = nil
    end

    if key.long_press_active then
      key.long_press_active = false
      if key.long_press_release then key.long_press_release(x, y) end
    end
  end
end

-- the current press should not be treated as short
function _key:short_press_cancel()
  self.press_time = nil
end

-- manually mark a press as long, calling long_press_start if not already in a long press
function _key:long_press_activate()
  if self.pressed then
    self.long_press_active = true
    self.press_time = nil -- not a short press

    if self.long_press_start then self.long_press_start(self.x, self.y) end
  end
end

return keyhelper
