inspect= require 'tools.inspect'
local pattern_time = require 'pattern_time'
local music = require 'musicutil'
local eloop = include 'lib/eloop'

local polysub = require 'polysub'

local g = grid.connect()
local grid_connected = g.device~= nil and true or false
local cols = grid_connected and g.device.cols or 16
local rows = grid_connected and g.device.rows or 8

-- forward declare functions
local pattern_record_start,pattern_record_stop,pattern_clear,grid_led_array_init,grid_press_array_init,grid_led_clear,note_hasher,tempo_change_handler,create_fixed_pulse,clear_fixed_pulse,start_holding,create_mod_pulse,add_to_held,stop_holding,remove_from_held,pattern_stop,pattern_start,note_id_to_info,start_note,matrix_coord_to_note_num,lighting_update_handler,grid_led_set,grid_led_add,grid_to_note_num,table_size,matrix_note,pattern_note,gridredraw,metronome,clear_pattern_notes,get_digit

local grid_led,grid_presses
local currently_playing = {}
local enc_control = 0
local pressed_notes = {}
local held_notes = {}
local holding = false
local bpm = clock.get_tempo()
local holding_led_pulse_level = 4
local grid_refresh_rate = 60
local screen_refresh_metro
local max_voices = 100

local options = {
  same_note_behavior = {"retrigger", "detuned", "ignore", "separate"}
}

-- to identify the source of a currently playing note
local sources = {
  pressed = 1,
  pattern1 = 2,
  pattern2 = 3
}

engine.name = 'PolySub'

-- current count of active voices
local nvoices = 0
local grid_window = {x = 5, y = 14}
local grid_window_transpose_indicator_nums = {21, 7}
if rows == 16 then
  grid_window.y = 18
  grid_window_transpose_indicator_nums = {25,11}
end
local lighting_over_time = {mod = {}, fixed = {}}
local row_interval = 5
local metrokey = false
local metrorun = 0
local metrolevel = 6
local metronome_mult = 1
local metronome_div = 1
local k1 = false
local ctrlkey = false
local metronome_sound = _path.code.."orison/metronome-tick.wav"
local retriggertracker = 0

local patterns = {}

local enc_control_options = {"shape","timbre","noise","cut","ampatk","amprel","pat1_tf","pat1_tf_sync_m","pat1_tf_sync_d","pat2_tf","pat2_tf_sync_m","pat2_tf_sync_d","clock_tempo"}

tempo_change_handler = function(tempo)
  if bpm ~= tempo then
    bpm = tempo

    for i,pattern in ipairs(patterns) do
      if pattern.sync and pattern.rec == 1 then
        pattern_record_stop(i)
        pattern_clear(i)
      end
    end
  end
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

start_note = function(id, note, detune)
  detune = detune or 0
  engine.start(id, music.note_num_to_freq(note) + detune)
end

clear_all_notes = function()
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

clear_pattern_notes = function(pattern_t)
  local notes_to_clear = {}
  for id,e in pairs(currently_playing) do
    if get_digit(id, 2) == sources[pattern_t.source_id] then
      notes_to_clear[id] = e
    end
  end

  for id,e in pairs(notes_to_clear) do
    currently_playing[e.id] = nil
    engine.stop(e.id)
    nvoices = nvoices - 1
  end
end

grid_to_note_num = function(x,y)
  note_num = (grid_window.y - y + 1)*5 + grid_window.x + x - 2
  return note_num
end

matrix_coord_to_note_num = function(x,y)
  return x + y*row_interval
end

matrix_note = function(e)
  local note_num = matrix_coord_to_note_num(e.x, e.y)
  if e.state > 0 then
    if nvoices < max_voices then
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
              e.id = get_nonconflicting_id(e.id)
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
              e.id = get_nonconflicting_id(e.id)
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
      -- TODO: get rid of this
      for i=0,99 do
        engine.stop(note_hash*100+i)
      end
    end

    engine.stop(e.id)
    nvoices = nvoices - 1
  end
end

--- CLOCKWORKS
metronome = function()
  while true do
    clock.sync(metronome_mult / metronome_div)

    softcut.position(1,0)
  end
end

--- PATTERNS
pattern_note = function(e)
  local note_num = matrix_coord_to_note_num(e.x, e.y)
  if e.state > 0 then
    if nvoices < max_voices then
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
            detune = (math.random() + 1) * (math.random(0, 1) * 2 - 1)

            -- if note already being played is from same source, change id to not conflict
            if currently_playing[e.id] ~= nil then
              -- print("before: "..e.id)
              e.id = get_nonconflicting_id(e.id)
              -- print("after: "..e.id)
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
              e.id = get_nonconflicting_id(e.id)
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

pattern_start = function(n)
  pattern = patterns[n].pattern

  if pattern.count == 0 then
    return
  end

  pattern.callbacks.start = function()
    local x,y,level
    if n == 1 then
      x = 1
      y = 3
      level = patterns[n].led_level
    elseif n == 2 then
      x = 1
      y = 4
      -- TODO: investigate this
      level = patterns[n].led_level + 2
    end

    grid_led[x][y].add = nil

    create_fixed_pulse(x,y,0,level,.9,"rise")
  end

  pattern:start()
end

pattern_stop = function(n)
  pattern = patterns[n].pattern

  pattern.callbacks.stop = function()
    clear_pattern_notes(patterns[n])

    local x,y
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

  pattern:stop()
end

pattern_record_start = function (n)
  pattern = patterns[n].pattern

  local x,y
  if n == 1 then
    x = 1
    y = 3
  elseif n == 2 then
    x = 1
    y = 4
  end
  local level = patterns[n].led_level


  -- immediately stop pattern
  if pattern.sync then
    pattern.sync = false
    pattern_stop(n)
    pattern.sync = true

    create_fixed_pulse(x,y,0,level,.3,"wave")
  else
    pattern_stop(n)
  end

  pattern:clear()

  pattern.callbacks.rec_start = function()
    for id, e in pairs(pressed_notes) do
      p = {}
      p.x = e.x
      p.y = e.y
      p.state = 1
      p.id = math.floor(e.id / 100) * 100 + sources["pattern" .. n] * 10

      pattern:watch(p)
    end

    clear_fixed_pulse(x,y)
    create_fixed_pulse(x,y,0,level,.9,"fall")
  end

  pattern:rec_start()
end

pattern_record_stop = function(n)
  pattern = patterns[n].pattern

  pattern.callbacks.rec_stop_pre = function()
    for id, e in pairs(pressed_notes) do
      p = {}
      p.x = e.x
      p.y = e.y
      p.state = 0
      p.id = math.floor(e.id / 100) * 100 + sources["pattern" .. n] * 10

      pattern:watch(p)
    end
  end

  pattern.callbacks.rec_stop_post = function()
    local x,y
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
    pattern_start(n)
  end

  pattern:rec_stop()
end

pattern_clear = function(n)
  pattern = patterns[n].pattern
  pattern.sync = false

  if pattern.play == 1 then
    pattern_stop(n)
  end

  pattern:clear()

  local x,y
  if n == 1 then
    x = 1
    y = 3
  elseif n == 2 then
    x = 1
    y = 4
  end

  grid_led[x][y].add = nil
end

--- DRAWING
lighting_update_handler = function()
  grid_led_clear()

  -- light c notes
  for x = 2,cols,1 do
    for y = 1,rows,1 do
      if grid_to_note_num(x,y) == 60 then
        grid_led_set(x,y,7)
      elseif grid_to_note_num(x,y) % 12 == 0 then
        grid_led_set(x,y,4)
      end
    end
  end

  -- light transpose keys
  grid_led_set(1, 1, math.floor((grid_window.y - grid_window_transpose_indicator_nums[2]) / 2))
  grid_led_set(1, 2, math.floor((grid_window_transpose_indicator_nums[1] - grid_window.y) / 2))

  for id,e in pairs(currently_playing) do
    note_info = note_id_to_info(id)
    if note_info.source == "1" then
      grid_led_add(e.x - grid_window.x + 2, grid_window.y - e.y + 1, 1)
    elseif note_info.source == "2" then
      grid_led_add(e.x - grid_window.x + 2, grid_window.y - e.y + 1, patterns[1].led_level)
    elseif note_info.source == "3" then
      grid_led_add(e.x - grid_window.x + 2, grid_window.y - e.y + 1, patterns[2].led_level)
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

  gridredraw()
end

grid_led_array_init = function()
  init_grid = {}

  for x=1,cols do
    init_grid[x] = {}
    for y=1,rows do
      init_grid[x][y] = {level = 0, dirty = false}
    end
  end

  return init_grid
end

grid_led_set = function(x, y, level)
  level = util.clamp(level,0,15)

  if x < 1 or x > cols or y < 1 or y > rows or level == grid_led[x][y].level then
    return
  else
    grid_led[x][y].level = level
    grid_led[x][y].dirty = true
  end
end

grid_led_add = function(x, y, val)
  if val == 0 or x < 1 or x > cols or y < 1 or y > rows then
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

grid_led_clear = function()
  for x=1,cols do
    for y=1,rows do
      grid_led[x][y].level = 0
      grid_led[x][y].dirty = true
    end
  end
end

gridredraw = function()
  for x=1,cols do
    for y=1,rows do
      if grid_led[x][y].add ~= nil then
        grid_led_add(x, y, grid_led[x][y].add)
      end

      -- if true then
      if grid_led[x][y].dirty then
        g:led(x,y,grid_led[x][y].level)
        grid_led[x][y].dirty = false
      end
    end
  end

  g:refresh()
end

create_fixed_pulse = function(x, y, pmin, pmax, rate, shape)
  pulse = {x = x, y = y, pmin = pmin, pmax = pmax, rate = rate, current = pmin, dir = 1, mode = "fixed", shape = shape}

  if shape == "wave" then
    pulse.frames_per_step = math.floor(0.5 + rate * grid_refresh_rate / (2*(pmax - pmin)))
  elseif shape == "rise" or shape == "fall" then
    pulse.frames_per_step = math.floor(0.5 + rate * grid_refresh_rate / (pmax - pmin))

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
    pulse.frames_per_step = math.floor(0.5 + rate * grid_refresh_rate / (2*range))
  elseif shape == "rise" or shape == "fall" then
    pulse.frames_per_step = math.floor(0.5 + rate * grid_refresh_rate / range)

    if shape == "fall" then
      pulse.dir = -1
      pulse.current = range
    end
  end
  pulse.frametrack = pulse.frames_per_step

  lighting_over_time.mod[note_id] = pulse

  return pulse
end

function redraw()
  screen.clear()

  screen.move(1,5)
  screen.level(4)
  screen.text("bpm: ".. bpm)

  if metrorun == 1 then
    screen.level(15)
  end
  screen.move(50,5)
  screen.text("div: " .. metronome_mult .. "/" .. metronome_div)

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
  local pattern = patterns[1].pattern
  if pattern.sync == false then
    screen.text("p1 tf: " .. pattern.time_factor)
  else
    screen.text("p1 tf: " .. pattern.time_factor_sync_mult .. " / " .. pattern.time_factor_sync_div)
  end

  screen.move(64,25)
  pattern = patterns[2].pattern
  if pattern.sync == false then
    screen.text("p2 tf: " .. pattern.time_factor)
  else
    screen.text("p2 tf: " .. pattern.time_factor_sync_mult .. " / " .. pattern.time_factor_sync_div)
  end

  current_beat_offset = clock.get_beats() % 1

  screen.level(math.floor((1 - current_beat_offset)^2 * 14))
  screen.circle(114,7,4)
  screen.fill()

  screen.update()
end

--- UTILS
note_hasher = function(x,y)
  return y*40 + x
end

note_id_to_info = function(id)
  id = id .. ""
  note_hash = id:sub(1,-3)
  y = math.floor(note_hash/40)
  x = note_hash - y*40
  return {x = x, y = y, source = id:sub(-2,-2), note_hash = note_hash}
end

get_nonconflicting_id = function(id)
  local ceil = (math.ceil(id/10) + 1) * 10
  local new_id = id
  while currently_playing[new_id] ~= nil do
    new_id = id + 1

    if id == ceil then
      id = ceil - 10
    end

    if new_id == id then
      error("Unable to obtain nonconflicting id for id "..id)
    end
  end

  return new_id
end

get_digit = function(num, digit)
  local n = 10 ^ digit
  local n1 = 10 ^ (digit - 1)
  return math.floor((num % n) / n1)
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

--- HARDWARE
grid_press_array_init = function()
  init_grid = {}

  for x=1,cols do
    init_grid[x] = {}
    for y=1,rows do
      init_grid[x][y] = 0
    end
  end

  return init_grid
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
        local n = y - 2
        local pattern = patterns[n].pattern
        local sync = pattern.sync

        if ctrlkey then
          pattern_stop(n)
          pattern_clear(n)
          pattern_record_start(n)
        elseif altkey then
          pattern_stop(n)
          pattern_clear(n)
          pattern.sync = true
          pattern_record_start(n)
        elseif pattern.rec == 0 and pattern.count == 0 then
          pattern_record_start(n)
        elseif pattern.rec == 1 then
          pattern_record_stop(n)
        elseif pattern.play == 0 then
          pattern_start(n)
        elseif pattern.play == 1 then
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
    patterns[1].pattern:watch(p)

    p2 = {}
    p2.x = grid_window.x + x - 2
    p2.y = grid_window.y - y + 1
    p2.state = z
    p2.id = note_hasher(grid_window.x + x - 2, grid_window.y - y + 1) * 100 + sources.pattern2 * 10
    patterns[2].pattern:watch(p2)

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
    elseif n == 2 then
      metronome_mult = util.clamp(metronome_mult + delta, 1, 1000000)
    elseif n == 3 then
      metronome_div = util.clamp(metronome_div + delta, 1, 1000000)
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
      if not patterns[1].pattern.sync then
        params:set("enc2",7)
      else
        params:set("enc2",9)
        params:set("enc1",8)
      end

      if not patterns[2].pattern.sync then
        params:set("enc3",10)
      else
        params:set("enc3",12)
        if not patterns[1].pattern.sync then
          params:set("enc1",11)
        end
      end

      if not patterns[1].pattern.sync and patterns[2].pattern.sync then
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

--- INIT
function init()
  for i=1,2 do
    local p = {}

    p.pattern = eloop.new()
    p.pattern.process = pattern_note
    p.source_id = "pattern"..i

    patterns[i] = p
  end
  patterns[1].led_level = 8
  patterns[2].led_level = 3
  patterns[1].pattern.callbacks.loop = function()
    clear_pattern_notes(patterns[1])
  end
  patterns[2].pattern.callbacks.loop = function()
    clear_pattern_notes(patterns[2])
  end


  params:add_separator("top_sep", "control")
  params:add_option("enc1","enc1", enc_control_options, 4)
  params:add_option("enc2","enc2", enc_control_options, 5)
  params:add_option("enc3","enc3", enc_control_options, 6)
  params:hide("enc1")
  params:hide("enc2")
  params:hide("enc3")
  params:add_option("same_note_behavior", "same note behavior", options.same_note_behavior, 2)

  local tf_control = controlspec.def{
    min = .01,
    max = 10,
    warp = 'exp',
    step = .001,
    default = 1,
    units = 'x time',
    quantum = 0.005,
    wrap = false
  }
  params:add_control("pat1_tf","pattern1 timef",tf_control)
  params:add_control("pat2_tf","pattern2 timef",tf_control)
  local mult_div_spec = controlspec.def{
      min = 1,
      max = 64,
      warp = 'lin',
      step = 1, -- value quantization
      default = 1,
      -- units = 'v',
      quantum = 1/63,
      wrap = false
  }
  params:add({
    id = "pat1_tf_sync_m",
    name = "pattern 1 sync mult",
    type = "control",
    controlspec = mult_div_spec
  })
  params:add({
    id = "pat1_tf_sync_d",
    name = "pattern 1 sync div",
    type = "control",
    controlspec = mult_div_spec
  })
  params:add({
    id = "pat2_tf_sync_m",
    name = "pattern 2 sync mult",
    type = "control",
    controlspec = mult_div_spec
  })
  params:add({
    id = "pat2_tf_sync_d",
    name = "pattern 2 sync div",
    type = "control",
    controlspec = mult_div_spec
  })

  params:set_action("pat1_tf", function(tf)
    patterns[1].pattern:set_time_factor(tf)
  end)

  params:set_action("pat2_tf", function(tf)
    patterns[2].pattern:set_time_factor(tf)
  end)

  params:set_action("pat1_tf_sync_m", function(i)
    patterns[1].pattern:set_time_factor_sync_mult(i)
  end)

  params:set_action("pat1_tf_sync_d", function(i)
    patterns[1].pattern:set_time_factor_sync_div(i)
  end)

  params:set_action("pat2_tf_sync_m", function(i)
    patterns[2].pattern:set_time_factor_sync_mult(i)
  end)

  params:set_action("pat2_tf_sync_d", function(i)
    patterns[2].pattern:set_time_factor_sync_div(i)
  end)

  local clock_tempo = params:lookup_param("clock_tempo")
  local current_action = clock_tempo.action
  clock_tempo.action = function(x)
    current_action(x)
    tempo_change_handler(x)
  end

  params:add_separator("polysub_sep", "polysub")
  polysub:params()

  engine.stopAll()
  params:bang()

  grid_led = grid_led_array_init()
  grid_presses = grid_press_array_init()

  grid_refresh_metro = metro.init()
  grid_refresh_metro.event = function(stage)
    lighting_update_handler()
    gridredraw()
  end
  grid_refresh_metro:start(1 / grid_refresh_rate)

  screen.aa(0)
  screen.line_width(1)
  screen_refresh_metro = metro.init()
  screen_refresh_metro.event = function()
    redraw()
  end
  screen_refresh_metro:start(1/60)

  metroid = clock.run(metronome)

  softcut.buffer_clear()
  softcut.buffer_read_mono(metronome_sound,0,0,-1,1,1)

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
  patterns[1].pattern:stop()
  patterns[1].pattern:stop()
  pat = nil
end
