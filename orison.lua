local tab = require 'tabutil'
local pattern_time = require 'pattern_time'
local music = require 'musicutil'

local polysub = require 'polysub'

local g = grid.connect()

grid_led = 1
grid_presses = 1

currently_playing = {}
local enc_control = 0
pressed_notes = {}
local held_notes = {}
local holding = false
local bpm = clock.get_tempo()
local pattern_1_led_level = 8
local pattern_2_led_level = 3
local holding_led_pulse_level = 4
local pattern1_timefactor = 1
local pattern1_basebpm = nil
local pattern1_synctf_num = 1
local pattern1_synctf_denom = 1
local pattern2_timefactor = 1
local pattern2_basebpm = nil
local pattern2_synctf_num = 1
local pattern2_synctf_denom = 1
clockids = {}

local visual_refresh_rate = 120
local screen_refresh_metro

local MAX_NUM_VOICES = 100

local options = {
  same_note_behavior = {"retrigger", "detuned", "ignore", "separate"}
}

local sources = {
  pressed = 1,
  pattern1 = 2,
  pattern2 = 3
}

engine.name = 'PolySub'

-- current count of active voices
local nvoices = 0

local grid_window = {x = 5, y = 14}
lighting_over_time = {mod = {}, fixed = {}}
local row_interval = 5
local metrokey = false
local metrorun = 0
local metrolevel = 6
local divnum = 1
local divdenom = 1
local k1 = false
local ctrlkey = false
local file = _path.dust.."audio/metro-tick.wav"
local retriggertracker = 0
local patterns = {}
local pattern1_sync = false
local reset_clock_id1 = nil
local stoparm1 = false
local pattern2_sync = false
local reset_clock_id2 = nil
local stoparm2 = false
local grid_metro_level = 0
local grid_metro_flash = false
local enc_control_options = {"shape","timbre","noise","cut","ampatk","amprel","pat1tf","pat1synctfn","pat1synctfd","pat2tf","pat2synctfn","pat2synctfd","clock_tempo"}

-- forward declare functions
local pattern_record_start,pattern_record_stop,pattern_clear,grid_led_array_init,grid_press_array_init,grid_led_clear,note_hasher,tempo_change_handler,create_fixed_pulse,clear_fixed_pulse,start_holding,create_mod_pulse,add_to_held,stop_holding,remove_from_held,pattern_stop,pattern_start,note_id_to_info,start_note,matrix_coord_to_note_num,pattern1_stop_sync,pattern2_stop_sync,pattern1_record_start_sync,pattern2_record_start_sync,pattern1_record_stop_sync,pattern2_record_stop_sync,pattern1_start_sync,pattern2_start_sync,pattern1_reset_sync,pattern2_reset_sync,lighting_update_handler,grid_led_set,grid_led_add,clear_notes,get_digit,grid_to_note_num,table_size,matrix_note,pattern_note,gridredraw,metronome

grid_led_array_init = function()
  init_grid = {}

  for x=1,16 do
    init_grid[x] = {}
    for y=1,8 do
      init_grid[x][y] = {level = 0, dirty = false}
    end
  end

  return init_grid
end

grid_press_array_init = function()
  init_grid = {}

  for x=1,16 do
    init_grid[x] = {}
    for y=1,8 do
      init_grid[x][y] = 0
    end
  end

  return init_grid
end

grid_led_clear = function()
  for x=1,16 do
    for y=1,8 do
      grid_led[x][y].level = 0
      grid_led[x][y].dirty = true
    end
  end
end

note_hasher = function(x,y)
  return y*40 + x
end

tempo_change_handler = function(tempo)
  if bpm ~= tempo then
    bpm = tempo
    if pattern1_sync == "clock" then
      if pat1.rec == 1 then
        pattern_record_stop(1)
        pattern_clear(1)
      else
        params:set("pat1tf",(pattern1_basebpm / bpm) * (params:get("pat1synctfn") / params:get("pat1synctfd")))
      end
    end

    if pattern2_sync == "clock" then
      if pat2.rec == 1 then
        pattern_record_stop(2)
        pattern_clear(2)
      else
        params:set("pat2tf",(pattern2_basebpm / bpm) * (params:get("pat2synctfn") / params:get("pat2synctfd")))
      end
    end
  end
end

create_fixed_pulse = function(x, y, pmin, pmax, rate, shape)
  pulse = {x = x, y = y, pmin = pmin, pmax = pmax, rate = rate, current = pmin, dir = 1, mode = "fixed", shape = shape}

  if shape == "wave" then
    pulse.frames_per_step = math.floor(0.5 + rate * visual_refresh_rate / (2*(pmax - pmin)))
  elseif shape == "rise" or shape == "fall" then
    pulse.frames_per_step = math.floor(0.5 + rate * visual_refresh_rate / (pmax - pmin))

    if shape == "fall" then
      pulse.dir = -1
      pulse.current = pmax
    end
  end
  pulse.frametrack = pulse.frames_per_step

  id = y*16 + x
  lighting_over_time.fixed[id] = pulse

  return pulse
end

clear_fixed_pulse = function(x, y)
  id = y*16 + x
  lighting_over_time.fixed[id] = nil
end

create_mod_pulse = function(range, rate, note_id, shape)
  pulse = {range = range, current = 0, dir = 1, mode = "mod", note_id = note_id, shape = shape}

  if shape == "wave" then
    pulse.frames_per_step = math.floor(0.5 + rate * visual_refresh_rate / (2*range))
  elseif shape == "rise" or shape == "fall" then
    pulse.frames_per_step = math.floor(0.5 + rate * visual_refresh_rate / range)

    if shape == "fall" then
      pulse.dir = -1
      pulse.current = range
    end
  end
  pulse.frametrack = pulse.frames_per_step

  lighting_over_time.mod[note_id] = pulse

  return pulse
end

start_holding = function()
  if holding then
    return
  end

  create_fixed_pulse(1, 8, 2, 8, .75, "rise")
  holding = true
end

add_to_held = function(note)
  note.pulser = create_mod_pulse(holding_led_pulse_level, .75, note.id, "rise")

  if holding then
    for id, e2 in pairs(held_notes) do
      note.pulser.frametrack = e2.pulser.frametrack
      note.pulser.dir = e2.pulser.dir
      note.pulser.current = e2.pulser.current
      break
    end
  end

  held_notes[note.id] = note
  start_holding()
end

stop_holding = function()
  for id in pairs(held_notes) do
    e = held_notes[id]
    e.state = 0
    held_notes[id] = nil
    matrix_note(e)
  end

  clear_fixed_pulse(1,8)
  holding = false
end

remove_from_held = function(id)
  e = held_notes[id]
  e.state = 0
  held_notes[id] = nil
  matrix_note(e)

  if table_size(held_notes) == 0 then
    stop_holding()
  end
end

pattern_stop = function(n)
  pattern = patterns[n].pattern
  pattern:stop()
  clear_notes("pattern" .. n)

  if n == 1 then
    x = 1
    y = 3
  elseif n == 2 then
    x = 1
    y = 4
  end

  if pattern.count == 0 then
    grid_led[x][y].add = nil
  else
    grid_led[x][y].add = 2
  end

  clear_fixed_pulse(x,y)
end

pattern1_stop_sync = function(n)
  stoparm1 = true

  if reset_clock_id1 ~= nil then
    clock.cancel(reset_clock_id1)
  end

  clock.sync(1)

  stoparm1 = false

  pat1:stop()
  clear_notes(pattern1)

  x = 1
  y = 3

  if pat1.count == 0 then
    grid_led[x][y].add = nil
  else
    grid_led[x][y].add = 2
  end

  clear_fixed_pulse(x,y)
end

pattern2_stop_sync = function(n)
  stoparm2 = true

  if reset_clock_id2 ~= nil then
    clock.cancel(reset_clock_id2)
  end

  clock.sync(1)

  stoparm2 = false

  pat2:stop()
  clear_notes(pattern2)

  x = 1
  y = 4

  if pat2.count == 0 then
    grid_led[x][y].add = nil
  else
    grid_led[x][y].add = 2
  end

  clear_fixed_pulse(x,y)
end

pattern_record_start = function (n)
  pattern = patterns[n].pattern

  if n == 1 then
    pattern1_sync = false
  elseif n == 2 then
    pattern2_sync = false
  else
    print("huh?")
  end

  --patterns[n].sync = false
  pattern_stop(n)
  pattern:clear()
  pattern:rec_start()

  for id, e in pairs(pressed_notes) do
    p = {}
    p.x = e.x
    p.y = e.y
    p.state = 1
    p.id = math.floor(e.id / 100) * 100 + sources["pattern" .. n] * 10

    pattern:watch(p)
  end

  if n == 1 then
    x = 1
    y = 3
    level = pattern_1_led_level
  elseif n == 2 then
    x = 1
    y = 4
    level = pattern_2_led_level + 2
  end

  create_fixed_pulse(x,y,0,level,.9,"fall")
end

pattern1_record_start_sync = function()
  pattern1_sync = "clock"
  pattern_stop(n)
  pat1:clear()

  x = 1
  y = 3
  level = pattern_1_led_level

  create_fixed_pulse(x,y,0,level,.3,"wave")

  clock.sync(1)

  clear_fixed_pulse(x,y)
  pattern1_basebpm = bpm

  pat1:rec_start()

  s = {}
  s.starter = true
  pat1:watch(s) 

  for id, e in pairs(pressed_notes) do
    p = {}
    p.x = e.x
    p.y = e.y
    p.state = 1
    p.id = math.floor(e.id / 100) * 100 + sources.pattern1 * 10

    pat1:watch(p)
  end

  create_fixed_pulse(x,y,0,level,.9,"fall")
end

pattern2_record_start_sync = function()
  pattern2_sync = "clock"
  pattern_stop(n)
  pat2:clear()

  x = 1
  y = 4
  level = pattern_2_led_level + 2

  create_fixed_pulse(x,y,0,level,.3,"wave")

  clock.sync(1)

  clear_fixed_pulse(x,y)
  pattern2_basebpm = bpm

  pat2:rec_start()

  s = {}
  s.starter = true
  pat2:watch(s) 

  for id, e in pairs(pressed_notes) do
    p = {}
    p.x = e.x
    p.y = e.y
    p.state = 1
    p.id = math.floor(e.id / 100) * 100 + sources.pattern2 * 10

    pat2:watch(p)
  end

  create_fixed_pulse(x,y,0,level,.9,"fall")
end

pattern_record_stop = function(n)
  pattern = patterns[n].pattern

  for id, e in pairs(pressed_notes) do
    p = {}
    p.x = e.x
    p.y = e.y
    p.state = 0
    p.id = math.floor(e.id / 100) * 100 + sources["pattern" .. n] * 10

    pattern:watch(p)
  end

  pattern:rec_stop()

  if n == 1 then
    pattern1_timefactor = 1
  elseif n == 2 then
    pattern2_timefactor = 1
  end

  if n == 1 then
    x = 1
    y = 3
  elseif n == 2 then
    x = 1
    y = 4
  end

  if pattern.count == 0 then
    grid_led[x][y].add = nil
  else
    grid_led[x][y].add = 2
  end

  clear_fixed_pulse(x,y)
end

pattern_start = function(n)
  pattern = patterns[n].pattern

  if pattern.count == 0 then
    return
  end

  pattern:start()

  if n == 1 then
    x = 1
    y = 3
    level = pattern_1_led_level
  elseif n == 2 then
    x = 1
    y = 4
    level = pattern_2_led_level + 2
  end

  grid_led[x][y].add = nil

  create_fixed_pulse(x,y,0,level,.9,"rise")
end

pattern1_record_stop_sync = function(n)
  s = {}
  s.syncer = true
  s.n = 1
  pat1:watch(s)

  clock.sync(1)

  for id, e in pairs(pressed_notes) do
    p = {}
    p.x = e.x
    p.y = e.y
    p.state = 0
    p.id = math.floor(e.id / 100) * 100 + sources.pattern1 * 10

    pat1:watch(p)
  end

  pat1:rec_stop()

  pattern1_timefactor = 1
  pattern1_synctf_num = 1
  pattern1_synctf_denom = 1

  x = 1
  y = 3

  if pat1.count == 0 then
    grid_led[x][y].add = nil
  else
    grid_led[x][y].add = 2
  end

  clear_fixed_pulse(x,y)

  if pat1.count == 2 then
    pattern_clear(n)
    return
  end

  pattern_start(1)
end

pattern2_record_stop_sync = function(n)
  s = {}
  s.syncer = true
  s.n = 2
  pat2:watch(s)

  clock.sync(1)

  for id, e in pairs(pressed_notes) do
    p = {}
    p.x = e.x
    p.y = e.y
    p.state = 0
    p.id = math.floor(e.id / 100) * 100 + sources.pattern2 * 10

    pat2:watch(p)
  end

  pat2:rec_stop()

  pattern2_timefactor = 1
  pattern2_synctf_num = 1
  pattern2_synctf_denom = 1

  x = 1
  y = 4

  if pat2.count == 0 then
    grid_led[x][y].add = nil
  else
    grid_led[x][y].add = 2
  end

  clear_fixed_pulse(x,y)

  if pat2.count == 2 then
    pattern_clear(n)
    return
  end

  pattern_start(2)
end

pattern1_start_sync = function(n)
  if pat1.count == 0 then
    return
  end

  clock.sync(1)

  pattern_start(1)
end

pattern2_start_sync = function(n)
  if pat2.count == 0 then
    return
  end

  clock.sync(1)

  pattern_start(2)
end

pattern1_reset_sync = function()
  if pat1.count == 0 then
    return
  end

  clock.sync(params:get("pat1synctfn") / params:get("pat1synctfd"))

  pattern_stop(1)

  reset_clock_id1 = nil

  pattern_start(1)
end

pattern2_reset_sync = function()
  if pat2.count == 0 then
    return
  end

  clock.sync(params:get("pat2synctfn") / params:get("pat2synctfd"))

  pattern_stop(2)

  reset_clock_id2 = nil

  pattern_start(2)
end

pattern_clear = function(n)
  pattern = patterns[n].pattern

  if pattern.play == 1 then
    pattern_stop(n)
  end

  pattern:clear()

  if n == 1 then
    x = 1
    y = 3
    pattern1_sync = false
  elseif n == 2 then
    x = 1
    y = 4
    pattern2_sync = false
  end

  grid_led[x][y].add = nil
end

function g.key(x, y, z)
  grid_presses[x][y] = z
  if x == 1 then
    if z == 1 then
      if y == 8 and not holding and not ctrlkey then
        for id, e in pairs(pressed_notes) do
          add_to_held(e)
        end
      elseif y == 8 and holding and not ctrlkey then
        stop_holding()
      elseif y == 8 and ctrlkey then
        for id, e in pairs(pressed_notes) do
          if held_notes[math.floor(id / 100) * 100 + 10 * sources.pressed] == nil then
            add_to_held(e)
          else
            remove_from_held(math.floor(id / 100) * 100 + 10 * sources.pressed)
          end
        end
      elseif y == 3 or y == 4 then
        n = y - 2
        pattern = patterns[n].pattern

        if n == 1 then
          sync = pattern1_sync
        elseif n == 2 then
          sync = pattern2_sync
        else
          print("huh?")
        end

        if ctrlkey then
          pattern_stop(n)
          pattern_clear(n)
          pattern_record_start(n)
        elseif altkey then
          pattern_stop(n)
          pattern_clear(n)
          if n == 1 then
            clock.run(pattern1_record_start_sync)
          elseif n == 2 then
            clock.run(pattern2_record_start_sync)
          else
            print("huh?")
          end
        elseif pattern.rec == 0 and pattern.count == 0 then
          pattern_record_start(n)
        elseif pattern.rec == 1 and sync == "clock" then
          if n == 1 then
            clock.run(pattern1_record_stop_sync)
          elseif n == 2 then
            clock.run(pattern2_record_stop_sync)
          else
            print("huh?")
          end
        elseif pattern.rec == 1 and sync == false then
          pattern_record_stop(n)
          pattern_start(n)
        elseif pattern.play == 0 and sync == "clock" then
          if n == 1 then
            clock.run(pattern1_start_sync)
          elseif n == 2 then
            clock.run(pattern2_start_sync)
          else
            print("huh?")
          end
        elseif pattern.play == 0 and sync == false then
          pattern_start(n)
        elseif pattern.play == 1 and sync == "clock" then

          if n == 1 then
            clock.run(pattern1_stop_sync)
          elseif n == 2 then
            clock.run(pattern2_stop_sync)
          else
            print("huh?")
          end
        elseif pattern.play == 1 and sync == false then
          pattern_stop(n)
        end
      elseif y == 1 then
        grid_window.y = grid_window.y + 1

        for id, e in pairs(pressed_notes) do
          e.y_transpose_since_press = e.y_transpose_since_press + 1
        end
      elseif y == 2 then
        grid_window.y = grid_window.y - 1

        for id, e in pairs(pressed_notes) do
          e.y_transpose_since_press = e.y_transpose_since_press - 1
        end
      elseif y == 6 then
        altkey = true
      elseif y == 7 then
        ctrlkey = true
      end
    elseif z == 0 then
      if y == 6 then
        altkey = false
      elseif y == 7 then
        ctrlkey = false
      end
    end
  else
    p = {}
    p.x = grid_window.x + x - 2
    p.y = grid_window.y - y + 1
    p.state = z
    p.id = note_hasher(grid_window.x + x - 2, grid_window.y - y + 1) * 100 + sources.pattern1 * 10 -- 2nd to last digit of ID specifies source
    pat1:watch(p)

    p2 = {}
    p2.x = grid_window.x + x - 2
    p2.y = grid_window.y - y + 1
    p2.state = z
    p2.id = note_hasher(grid_window.x + x - 2, grid_window.y - y + 1) * 100 + sources.pattern2 * 10 
    pat2:watch(p2)

    e = {}
    e.x = grid_window.x + x - 2
    e.y = grid_window.y - y + 1
    e.state = z
    e.id = note_hasher(grid_window.x + x - 2, grid_window.y - y + 1) * 100 + sources.pressed * 10 

    if z == 1 then
      if ctrlkey and grid_presses[1][8] == 1 then
        if held_notes[e.id] ~= nil then
          remove_from_held(e.id)
        else
          add_to_held(e)
          matrix_note(e)
        end
      else
        matrix_note(e)
        e.x_transpose_since_press = 0
        e.y_transpose_since_press = 0
        pressed_notes[e.id] = e
      end
    else
      for id, e2 in pairs(pressed_notes) do
        if (grid_window.x + x - 2) == (e2.x + e2.x_transpose_since_press) and (grid_window.y - y + 1) == (e2.y + e2.y_transpose_since_press) then
          e2.state = 0
          matrix_note(e2)
          pressed_notes[id] = nil
          return
        end
      end
      pressed_notes[e.id] = nil
      matrix_note(e)
    end
  end
  --gridredraw()
end

note_id_to_info = function(id)
  id = id .. ""
  note_hash = id:sub(1,-3)
  y = math.floor(note_hash/40)
  x = note_hash - y*40
  return {x = x, y = y, source = id:sub(-2,-2), note_hash = note_hash}
end

lighting_update_handler = function()
  grid_led_clear()

  -- light c notes
  for x = 2,16,1 do
    for y = 1,8,1 do
      if grid_to_note_num(x,y) == 60 then
        grid_led_set(x,y,7)
      elseif grid_to_note_num(x,y) % 12 == 0 then
        grid_led_set(x,y,4)
      end
    end
  end

  -- light transpose keys
  grid_led_set(1, 1, math.floor((grid_window.y - 7) / 2))
  grid_led_set(1, 2, math.floor((21 - grid_window.y) / 2))

  for id,e in pairs(currently_playing) do
    note_info = note_id_to_info(id)
    if note_info.source == "1" then
      grid_led_add(e.x - grid_window.x + 2, grid_window.y - e.y + 1, 1)
    elseif note_info.source == "2" then
      grid_led_add(e.x - grid_window.x + 2, grid_window.y - e.y + 1, pattern_1_led_level)
    elseif note_info.source == "3" then
      grid_led_add(e.x - grid_window.x + 2, grid_window.y - e.y + 1, pattern_2_led_level)
    end

    if e.pulser ~= nil then
      grid_led_add(e.x - grid_window.x + 2, grid_window.y - e.y + 1, e.pulser.current) 
    end
  end

  for i, obj in pairs(lighting_over_time.fixed) do
    obj.frametrack = obj.frametrack - 1
    grid_led_set(obj.x, obj.y, obj.current)

    if obj.frametrack == 0 then
      obj.current = obj.current + obj.dir

      if obj.current == obj.pmin then
        obj.dir = 1

        if obj.shape == "fall" then
          obj.current = obj.pmax
          obj.dir = -1
        end
      elseif obj.current == obj.pmax then
        obj.dir = -1

        if obj.shape == "rise" then
          obj.current = obj.pmin
          obj.dir = 1
        end
      end

      obj.frametrack = obj.frames_per_step
    end
  end

  for i, obj in pairs(lighting_over_time.mod) do
    obj.frametrack = obj.frametrack - 1
    if obj.frametrack == 0 then
      obj.current = obj.current + obj.dir
      if obj.current == 0 then
        obj.dir = 1

        if obj.shape == "fall" then
          obj.current = obj.range
          obj.dir = -1
        end
      elseif obj.current == obj.range then
        obj.dir = -1        

        if obj.shape == "rise" then
          obj.current = 0
          obj.dir = 1
        end
      end

      obj.frametrack = obj.frames_per_step
    end
  end

  for x=1,16 do
    for y=1,8 do
      grid_led_add(x,y,grid_metro_level)
    end
  end

  grid_metro_level = util.clamp(grid_metro_level - 1, 0, 15)

  gridredraw()
end

grid_led_set = function(x, y, level)
  level = util.clamp(level,0,15)

  if x < 1 or x > 16 or y < 1 or y > 8 or level == grid_led[x][y].level then
    return
  else
    grid_led[x][y].level = level
    grid_led[x][y].dirty = true
  end
end

grid_led_add = function(x, y, val)
  if val == 0 or x < 1 or x > 16 or y < 1 or y > 8 then
    return
  end

  level = grid_led[x][y].level

  if val > 0 and level == 15 then
    return
  elseif val < 0 and level == 0 then
    return
  else
    grid_led[x][y].level = util.clamp(level + val, 0, 15)
  end
end

start_note = function(id, note, detune)
  detune = detune or 0
  engine.start(id, music.note_num_to_freq(note) + detune)
end

clear_notes = function(source)
  source = source or "all"

  if source == "all" then
    for id,e in pairs(currently_playing) do
      currently_playing[id] = nil
      e.state = 0
      matrix_note(e)
    end

    for id in pairs(pressed_notes) do
      pressed_notes[id] = nil
    end

    if holding then
      for id in pairs(held_notes) do
        held_notes[id] = nil
      end
      lighting_over_time.fixed[129] = nil
      holding = false
    end
  end

  if source == "pattern1" then
    for id, e in pairs(currently_playing) do
      if get_digit(id, 2) == sources.pattern1 then
        e.state = 0
        matrix_note(e)
        e.state = 1
      end
    end
  end

  if source == "pattern2" then
    for id, e in pairs(currently_playing) do
      if get_digit(id, 2) == sources.pattern2 then
        currently_playing[id] = nil
        e.state = 0
        matrix_note(e)
        e.state = 1
      end
    end
  end
end

get_digit = function(num, digit)
  local n = 10 ^ digit
  local n1 = 10 ^ (digit - 1)
  return math.floor((num % n) / n1)
end

grid_to_note_num = function(x,y)
  note_num = (grid_window.y - y + 1)*5 + grid_window.x + x - 2
  return note_num
end

matrix_coord_to_note_num = function(x,y)
  return x + y*row_interval
end

table_size = function(table)
  count = 0
  for key, val in pairs(table) do 
    print("key: " .. key .. " val: " .. val.id)
    count = count + 1 
  end
  print("number of elements: " .. count)
  return count
end

matrix_note = function(e)
  local note_num = matrix_coord_to_note_num(e.x, e.y)
  if e.state > 0 then
    if nvoices < MAX_NUM_VOICES then
      id = e.id .. ""
      note_hash = id:sub(1,-3)
      detune = 0
      for id2,e2 in pairs(currently_playing) do
        id2 = id2 .. ""
        note_hash2 = id2:sub(1,-3)
        if note_hash == note_hash2 then
          if params:string("same_note_behavior") == "ignore" then
            return
          elseif params:string("same_note_behavior") == "detuned" then
            detune = math.random(-1, 1) * 3

            -- if note already being played is from same source, change id to not conflict
            if currently_playing[e.id] ~= nil then
              while currently_playing[e.id] ~= nil do
                e.id = e.id + 1
              end
            end
          elseif params:string("same_note_behavior") == "retrigger" then
            -- stop engine from playing any instance of same note, but leave note in currently_playing
            for i=0,99 do
              engine.stop(note_hash2*100+i)
            end
            nvoices = nvoices - 1

            if currently_playing[e.id] ~= nil then
              while currently_playing[e.id] ~= nil do
                retriggertracker = retriggertracker + 1
                e.id = math.floor(e.id / 10) * 10 + util.wrap(retriggertracker, 0, 9)
              end
            end
          elseif params:string("same_note_behavior") == "separate" then
            if currently_playing[e.id] ~= nil then
              while currently_playing[e.id] ~= nil do
                e.id = e.id + 1
              end
            end 
          end
        end
      end
      start_note(e.id, note_num, detune)
      currently_playing[e.id] = e
      nvoices = nvoices + 1
    else
      print("maximum voices reached")
    end
  else
    if held_notes[e.id] ~= nil then
      return
    end

    currently_playing[e.id] = nil

    --if in retrigger mode, only stop note if no other sources are playing it
    if params:string("same_note_behavior") == "retrigger" then
      id = e.id .. ""
      note_hash = id:sub(1,-3)
      detune = 0
      for id2,e2 in pairs(currently_playing) do
        id2 = id2 .. ""
        note_hash2 = id2:sub(1,-3)
        if note_hash == note_hash2 then
          return -- if another source is playing the note, don't stop engine
        end
      end

      --since no instances of same note are playing, stop any possible instance of the note
      for i=0,99 do
        engine.stop(note_hash*100+i)
      end
    end

    engine.stop(e.id)
    nvoices = nvoices - 1
  end
end

pattern_note = function(e)
  if e.starter == true then
    return
  elseif e.syncer then
    if e.n == 1 and stoparm1 ~= true then
      reset_clock_id1 = clock.run(pattern1_reset_sync)
    elseif e.n == 2 and stoparm2 ~= true then
      reset_clock_id2 = clock.run(pattern2_reset_sync)
    end

    return
  end

  local note_num = matrix_coord_to_note_num(e.x, e.y)
  if e.state > 0 then
    if nvoices < MAX_NUM_VOICES then
      id = e.id .. ""
      note_hash = id:sub(1,-3)
      detune = 0
      for id2,e2 in pairs(currently_playing) do
        id2 = id2 .. ""
        note_hash2 = id2:sub(1,-3)
        if note_hash == note_hash2 then
          if params:string("same_note_behavior") == "ignore" then
            return
          elseif params:string("same_note_behavior") == "detuned" then
            detune = math.random(-1, 1) * 3

            -- if note already being played is from same source, change id to not conflict
            if currently_playing[e.id] ~= nil then
              while currently_playing[e.id] ~= nil do
                e.id = e.id + 1
              end
            end
          elseif params:string("same_note_behavior") == "retrigger" then
            -- stop engine from playing any instance of same note, but leave note in currently_playing
            for i=0,99 do
              engine.stop(note_hash2*100+i)
            end
            nvoices = nvoices - 1

            if currently_playing[e.id] ~= nil then
              while currently_playing[e.id] ~= nil do
                retriggertracker = retriggertracker + 1
                e.id = e.id + util.wrap(retriggertracker, 0, 9)
              end
            end
          elseif params:string("same_note_behavior") == "separate" then
            if currently_playing[e.id] ~= nil then
              while currently_playing[e.id] ~= nil do
                e.id = e.id + 1
              end
            end 
          end
        end
      end
      start_note(e.id, note_num, detune)
      currently_playing[e.id] = e
      nvoices = nvoices + 1
    else
      print("maximum voices reached")
    end
  else
    currently_playing[e.id] = nil

    --if in retrigger mode, only stop note if no other sources are playing it
    if params:string("same_note_behavior") == "retrigger" then
      id = e.id .. ""
      note_hash = id:sub(1,-3)
      detune = 0
      for id2,e2 in pairs(currently_playing) do
        id2 = id2 .. ""
        note_hash2 = id2:sub(1,-3)
        if note_hash == note_hash2 then
          return -- if another source is playing the note, don't stop engine
        end
      end

      --since no instances of same note are playing, stop any possible instance of the note
      for i=0,99 do
        engine.stop(note_hash*100+i)
      end
    end

    engine.stop(e.id)
    nvoices = nvoices - 1
  end
end

gridredraw = function()
  --g:all(0)

  for x=1,16 do 
    for y=1,8 do
      if true then
        --if grid_led[x][y].dirty then
        if grid_led[x][y].add ~= nil then
          grid_led_add(x, y, grid_led[x][y].add)
        end

        g:led(x,y,grid_led[x][y].level)
      end
    end
  end

  g:refresh()
end

function enc(n,delta)
  if metrokey and k1 then
    if n == 1 then
      metrolevel = util.clamp(metrolevel + delta/10, 0, 50)
      softcut.level(1, metrolevel)
    elseif n == 2 then
      placeholder = 1
    elseif n == 3 then
      placeholder = 1
    end
  elseif metrokey then
    if n == 1 then
      bpm = util.clamp(bpm + delta, 1, 300)
      params:set("clock_tempo", bpm)

      if pattern1_sync == "clock" then
        if pat1.rec == 1 then
          pattern_record_stop(1)
          pattern_clear(1)
        else
          params:set("pat1tf",(pattern1_basebpm / bpm) * (params:get("pat1synctfn") / params:get("pat1synctfd")))
        end
      end

      if pattern2_sync == "clock" then
        if pat2.rec == 1 then
          pattern_record_stop(2)
          pattern_clear(2)
        else
          params:set("pat2tf",(pattern2_basebpm / bpm) * (params:get("pat2synctfn") / params:get("pat2synctfd")))
        end
      end
    elseif n == 2 then
      divnum = util.clamp(divnum + delta, 1, 1000000)
    elseif n == 3 then
      divdenom = util.clamp(divdenom + delta, 1, 1000000)
    end
  elseif k1 then
    if n == 1 then
      params:set("output_level", params:get("output_level") + delta/2)
    elseif n == 2 then
      placeholder = 1
    elseif n == 3 then
      placeholder = 1
    end
  elseif n == 1 then
    params:delta(params:string("enc1"), delta/2)
  elseif n == 2 then
    params:delta(params:string("enc2"), delta/2)
  elseif n == 3 then
    params:delta(params:string("enc3"), delta/2)
  end
  redraw()
end

function key(n,z)
  if metrokey and n == 3 and z == 1 then
    metrorun = 1 - metrorun
    if metrorun == 1 then
      softcut.level(1, metrolevel)
    else
      softcut.level(1, 0)
    end
  elseif n == 2 and z == 1 then
    if ctrlkey then grid_metro_flash = not grid_metro_flash end
    if enc_control == 2 then
      if params:get("enc1") == 8 then
        params:set("enc1",11)
      elseif params:get("enc1") == 11 then
        params:set("enc1",8)
      end
    end

    metrokey = true
  elseif n == 2 and z == 0 then
    metrokey = false
  elseif n == 3 and z == 1 then
    enc_control = enc_control - 1
    if enc_control < 0 then
      enc_control = 2
    end

    if enc_control == 0 then
      params:set("enc1",4)
      params:set("enc2",5)
      params:set("enc3",6)
    elseif enc_control == 1 then
      params:set("enc1",3)
      params:set("enc2",1)
      params:set("enc3",2)
    elseif enc_control == 2 then
      if pattern1_sync == false then
        params:set("enc2",7)
      elseif pattern1_sync == "clock" then
        params:set("enc2",9)
        params:set("enc1",8)
      end

      if pattern2_sync == false then
        params:set("enc3",10)
      elseif pattern2_sync == "clock" then
        params:set("enc3",12)
        if pattern1_sync ~= "clock" then
          params:set("enc1",11)
        end
      end

      if pattern1_sync == false and pattern1_sync == false then
        params:set("enc1",13)
      end
    end
  elseif n == 1 and z == 1 then
    k1 = true
  elseif n == 1 and z == 0 then
    k1 = false
  end
  redraw()
end

metronome = function()
  while true do
    clock.sync(divnum / divdenom)
    if grid_metro_flash then
      grid_metro_level = 4
    end

    softcut.position(1,0)
  end
end

function redraw()
  screen.clear()
  screen.aa(0)
  screen.line_width(1)

  screen.move(1,5)
  screen.level(4)
  screen.text("bpm: ".. bpm)

  if metrorun == 1 then
    screen.level(15)
  end
  screen.move(50,5)
  screen.text("div: " .. divnum .. "/" .. divdenom)

  if enc_control == 0 then
    screen.level(15)
  else
    screen.level(4)
  end
  screen.move(1,14)
  screen.text("amp atk: " .. params:string("ampatk"))
  screen.move(1,23)
  screen.text("amp rel: " .. params:string("amprel"))
  screen.move(1,32)
  screen.text("cut: " .. params:string("cut"))

  if enc_control == 1 then
    screen.level(15)
  else
    screen.level(4)
  end
  screen.move(1,41)
  screen.text("shape: " .. params:string("shape"))
  screen.move(1, 50)
  screen.text("timbre: " .. params:string("timbre")) 
  screen.move(1,59)
  screen.text("noise: " .. params:string("noise"))

  if enc_control == 2 then
    screen.level(15)
  else
    screen.level(4)
  end
  screen.move(64,16)
  if pattern1_sync == false then
    screen.text("p1 tf: " .. params:get("pat1tf"))
  elseif pattern1_sync == "clock" then
    screen.text("p1 tf: " .. params:get("pat1synctfn") .. " / " .. params:get("pat1synctfd"))
  end

  screen.move(64,25)
  if pattern2_sync == false then
    screen.text("p2 tf: " .. params:get("pat2tf"))
  elseif pattern2_sync == "clock" then
    screen.text("p2 tf: " .. params:get("pat2synctfn") .. " / " .. params:get("pat2synctfd"))
  end

  -- --draw metronome visualizer
  -- screen.level(14)
  -- screen.move(88,4)
  -- screen.line_width(1)
  -- screen.line(112,4)
  -- screen.stroke()

  current_beat_offset = clock.get_beats() % 1
  -- --screen.level(math.floor(.5 + current_beat_offset^2 * 15))
  -- screen.level(15)
  -- screen.move(88 + current_beat_offset * 23, 2.5 - current_beat_offset * 2.5)
  -- screen.line(88 + current_beat_offset * 23, 4.5 + current_beat_offset * 2.5)
  -- -- screen.move(107 + current_beat_offset * 19,0)
  -- -- screen.line(107 + current_beat_offset * 19,7)
  -- screen.stroke()

  -- screen.level(math.floor((1 - current_beat_offset)^2 * 13) + 1)
  -- screen.rect(111,0,7,7)
  -- screen.fill()

  screen.level(math.floor((1 - current_beat_offset)^2 * 14))
  screen.circle(114,7,4)
  screen.fill()

  screen.update()
end

function init()
  pat1 = pattern_time.new()
  pat1.process = pattern_note
  patterns[1] = {}
  patterns[1].pattern = pat1
  patterns[1].sync = false

  pat2 = pattern_time.new()
  pat2.process = pattern_note
  patterns[2] = {}
  patterns[2].pattern = pat2
  patterns[2].sync = false

  params:add_option("enc1","enc1", enc_control_options, 4)
  params:add_option("enc2","enc2", enc_control_options, 5)
  params:add_option("enc3","enc3", enc_control_options, 6)
  params:add_option("same_note_behavior", "same note behavior", options.same_note_behavior, 2)
  tf_control = controlspec.new(.01,100,'lin',.01,1,'x time',0.0001,false)
  params:add_control("pat1tf","pattern1 timef",tf_control)
  params:add_control("pat2tf","pattern2 timef",tf_control)
  tf_mult_control = controlspec.new(1,64,'lin',1,1)
  params:add_control("pat1synctfn","pattern 1 sync numer",tf_mult_control)
  params:add_control("pat1synctfd","pattern 1 sync denom",tf_mult_control)
  params:add_control("pat2synctfn","pattern 2 sync numer",tf_mult_control)
  params:add_control("pat2synctfd","pattern 2 sync denom",tf_mult_control)
  params:hide("pat1tf")
  params:hide("pat2tf")
  params:hide("pat1synctfn")
  params:hide("pat1synctfd")
  params:hide("pat2synctfn")
  params:hide("pat2synctfd")

  params:set_action("pat1tf", function(tf)
    pat1:set_time_factor(tf)
  end)

  params:set_action("pat2tf", function(tf)
    pat2:set_time_factor(tf)
  end)

  params:set_action("pat1synctfn", function(n)
    if pattern1_sync == "clock" then
      params:set("pat1tf",(pattern1_basebpm / bpm) * (params:get("pat1synctfn") / params:get("pat1synctfd")))
      if reset_clock_id1 ~= nil then
        clock.cancel(reset_clock_id1)
        --reset_clock_id1 = clock.run(pattern1_reset_sync)
        reset_clock_id1 = nil
      end
    end
  end)

  params:set_action("pat1synctfd", function(n)
    if pattern1_sync == "clock" then
      params:set("pat1tf",(pattern1_basebpm / bpm) * (params:get("pat1synctfn") / params:get("pat1synctfd")))
      if reset_clock_id1 ~= nil then
        clock.cancel(reset_clock_id1)
        --reset_clock_id1 = clock.run(pattern1_reset_sync)
        reset_clock_id1 = nil
      end
    end
  end)

  params:set_action("pat2synctfn", function(n)
    if pattern2_sync == "clock" then
      params:set("pat2tf",(pattern2_basebpm / bpm) * (params:get("pat2synctfn") / params:get("pat2synctfd")))
      if reset_clock_id2 ~= nil then
        clock.cancel(reset_clock_id2)
        reset_clock_id2 = clock.run(pattern2_reset_sync)
      end
    end
  end)

  params:set_action("pat2synctfd", function(n)
    if pattern2_sync == "clock" then
      params:set("pat2tf",(pattern2_basebpm / bpm) * (params:get("pat2synctfn") / params:get("pat2synctfd")))
      if reset_clock_id2 ~= nil then
        clock.cancel(reset_clock_id2)
        reset_clock_id2 = clock.run(pattern2_reset_sync)
      end
    end
  end)

  local clock_tempo = params:lookup_param("clock_tempo")
  local current_action = clock_tempo.action
  clock_tempo.action = function(x)
    current_action(x)
    tempo_change_handler(x)
  end

  params:add_separator()

  polysub:params()

  params:add_separator()

  engine.stopAll()

  params:bang()

  grid_led = grid_led_array_init()
  grid_presses = grid_press_array_init()

  grid_refresh_metro = metro.init()
  grid_refresh_metro.event = function(stage)
    lighting_update_handler()
    gridredraw()
  end
  grid_refresh_metro:start(1 / visual_refresh_rate)

  screen_refresh_metro = metro.init()
  screen_refresh_metro.event = function(stage)
    redraw()
  end
  screen_refresh_metro:start(1/60)

  metroid = clock.run(metronome)

  softcut.buffer_clear()
  softcut.buffer_read_mono(file,0,0,-1,1,1)

  softcut.enable(1,1)
  softcut.buffer(1,1)
  softcut.level(1,0)
  softcut.loop(1,0)
  softcut.loop_start(1,0)
  softcut.loop_end(1,1)
  softcut.position(1,1)
  softcut.rate(1,1.0)
  softcut.fade_time(1,0)
  softcut.play(1,1)
end

function reload()
  norns.script.load(norns.state.script)
end

function cleanup()
  pat:stop()
  pat = nil
end
