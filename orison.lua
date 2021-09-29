local tab = require 'tabutil'
local pattern_time = require 'pattern_time'
local music = require 'musicutil'

local polysub = include 'we/lib/polysub'

local g = grid.connect()

grid_led = 1
grid_presses = 1

currently_playing = {}
local enc_control = 0
pressed_notes = {}
local held_notes = {}
local holding = false
local pattern_1_led_level = 8
local pattern_2_led_level = 3
local holding_led_pulse_level = 4
local pattern1_timefactor = 1
local pattern2_timefactor = 1
clockids = {}

local visual_refresh_rate = 30
local screen_refresh_metro

local MAX_NUM_VOICES = 100

local options = {
  same_note_behavior = {"retrigger", "detuned", "ignore", "separate"}
}

local sources = {pressed = 1,
  pattern1 = 2,
  pattern2 = 3}

  engine.name = 'PolySub'

-- current count of active voices
local nvoices = 0

local grid_window = {x = 5, y = 14}
lighting_over_time = {mod = {}, fixed = {}}
local row_interval = 5
local metrokey = false
local metrorun = 0
local metrolevel = 6
local bpm = clock.get_tempo()
local divnum = 1
local divdenom = 1
local k1 = false
local ctrlkey = false
local file = _path.dust.."audio/metro-tick.wav"
local retriggertracker = 0
local enc_control_timefactor = false
local patterns = {}
local grid_metro_level = 0
local grid_metro_flash = false
local prev_time = 0

local function grid_led_array_init()
  init_grid = {}

  for x=1,16 do
    init_grid[x] = {}
    for y=1,8 do
      init_grid[x][y] = {level = 0, dirty = false}
    end
  end

  return init_grid
end

local function grid_press_array_init()
  init_grid = {}

  for x=1,16 do
    init_grid[x] = {}
    for y=1,8 do
      init_grid[x][y] = 0
    end
  end

  return init_grid
end

local function grid_led_clear()
  for x=1,16 do
    for y=1,8 do
      grid_led[x][y].level = 0
      grid_led[x][y].dirty = true
    end
  end
end

local function note_hasher(x,y)
  return y*40 + x
end

function init()
  m = midi.connect()
  m.event = midi_event

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

  params:add_option("enc1","enc1", {"shape","timbre","noise","cut","ampatk","amprel"}, 4)
  params:add_option("enc2","enc2", {"shape","timbre","noise","cut","ampatk","amprel"}, 5)
  params:add_option("enc3","enc3", {"shape","timbre","noise","cut","ampatk", "amprel"}, 6)
  params:add_option("same_note_behavior", "same note behavior", options.same_note_behavior, 2)

  params:add_separator()

  polysub:params()

  params:add_separator()
  
  engine.stopAll()

  params:bang()

  grid_led = grid_led_array_init()
  grid_presses = grid_press_array_init()

  screengrid_refresh_metro = metro.init()
  screengrid_refresh_metro.event = function(stage)
    lighting_update_handler()
    redraw()
    gridredraw()
  end
  screengrid_refresh_metro:start(1 / visual_refresh_rate)
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

local function create_fixed_pulse(x, y, pmin, pmax, rate, shape)
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

local function clear_fixed_pulse(x, y)
  id = y*16 + x
  lighting_over_time.fixed[id] = nil
end


local function create_mod_pulse(range, rate, note_id, shape)
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

local function start_holding()
  if holding then
    return
  end

  create_fixed_pulse(1, 8, 2, 8, .75, "rise")
  holding = true
end

local function add_to_held(note)
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

local function stop_holding()
  for id in pairs(held_notes) do
    e = held_notes[id]
    e.state = 0
    held_notes[id] = nil
    matrix_note(e)
  end

  clear_fixed_pulse(1,8)
  holding = false
end

local function remove_from_held(id)
  e = held_notes[id]
  e.state = 0
  held_notes[id] = nil
  matrix_note(e)

  if table_size(held_notes) == 0 then
    stop_holding()
  end
end

local function pattern_stop(n)
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

function pattern_stop_sync(n)
  print("pattern stop sync " .. n)

  pattern = patterns[n].pattern
  patterns[n].stoparm = true

  if patterns[n].reset_clock_id ~= nil then
    clock.cancel(patterns[n].reset_clock_id)
  end

  clock.sync(1)

  patterns[n].stoparm = false
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

local function pattern_record_start(n)
  pattern = patterns[n].pattern
  patterns[n].sync = false
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

function pattern_record_start_sync(n)
  print("pattern rec start sync" .. n)
  patterns[n].sync = "clock"
  pattern = patterns[n].pattern
  pattern_stop(n)
  pattern:clear()

  if n == 1 then
    x = 1
    y = 3
    level = pattern_1_led_level
  elseif n == 2 then
    x = 1
    y = 4
    level = pattern_2_led_level + 2
  end

  create_fixed_pulse(x,y,0,level,.3,"wave")

  clock.sync(1)
  
  clear_fixed_pulse(x,y)
  
  pattern:rec_start()

  s = {}
  s.starter = true
  pattern:watch(s) 

  for id, e in pairs(pressed_notes) do
    p = {}
    p.x = e.x
    p.y = e.y
    p.state = 1
    p.id = math.floor(e.id / 100) * 100 + sources["pattern" .. n] * 10

    pattern:watch(p)
  end

  create_fixed_pulse(x,y,0,level,.9,"fall")
end


local function pattern_record_stop(n)
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

local function pattern_start(n)
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

function pattern_record_stop_sync(n)
  print("pattern rec stop sync " .. n)
  pattern = patterns[n].pattern

  s = {}
  s.syncer = true
  s.n = n
  pattern:watch(s)
  
  clock.sync(1)

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

  if pattern.count == 2 then
    pattern_clear(n)
    return
  end

  pattern_start(n)
end

function pattern_start_sync(n)
  print("pattern start sync " .. n)
  pattern = patterns[n].pattern

  if pattern.count == 0 then
    return
  end

  clock.sync(1)

  pattern_start(n)
end

function pattern_reset_sync(n)
  print("pattern reset sync" .. n)
  pattern = patterns[n].pattern

  if pattern.count == 0 then
    return
  end

  clock.sync(1)

  pattern_stop(n)
  patterns[n].reset_clock_id = nil
  pattern_start(n)
end

local function pattern_clear(n)
  pattern = patterns[n].pattern

  if pattern.play == 1 then
    pattern_stop(n)
  end

  pattern:clear()

  if n == 1 then
    x = 1
    y = 3
  elseif n == 2 then
    x = 1
    y = 4
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
        if ctrlkey then
          pattern_stop(n)
          pattern_clear(n)
          pattern_record_start(n)
        elseif altkey then
          pattern_stop(n)
          pattern_clear(n)
          print(clock.run(pattern_record_start_sync, n))
        elseif pattern.rec == 0 and pattern.count == 0 then
          pattern_record_start(n)
        elseif pattern.rec == 1 and patterns[n].sync == "clock" then
          print(clock.run(pattern_record_stop_sync, n))
        elseif pattern.rec == 1 and patterns[n].sync == false then
          pattern_record_stop(n)
          pattern_start(n)
        elseif pattern.play == 0 and patterns[n].sync == "clock" then
          print(clock.run(pattern_start_sync, n))
        elseif pattern.play == 0 and patterns[n].sync == false then
          pattern_start(n)
        elseif pattern.play == 1 and patterns[n].sync == "clock" then
          print(clock.run(pattern_stop_sync, n))
        elseif pattern.play == 1 and patterns[n].sync == false then
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

function forid(id)
  if clockids[id] == nil then
    clockids[id] = true
  else
    print("clock id already exists")
  end
end


local function note_id_to_info(id)
  id = id .. ""
  note_hash = id:sub(1,-3)
  y = math.floor(note_hash/40)
  x = note_hash - y*40
  return {x = x, y = y, source = id:sub(-2,-2), note_hash = note_hash}
end

function lighting_update_handler()
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

function grid_led_set(x, y, level)
  level = util.clamp(level,0,15)

  if x < 1 or x > 16 or y < 1 or y > 8 or level == grid_led[x][y].level then
    return
  else
    grid_led[x][y].level = level
    grid_led[x][y].dirty = true
  end
end

function grid_led_add(x, y, val)
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

local function start_note(id, note, detune)
  detune = detune or 0
  engine.start(id, music.note_num_to_freq(note) + detune)
end  

local function stop_note(id)
  if params:get("output") == 1 then
    engine.stop(id)
  end      
end

function clear_notes(source)
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

function get_digit(num, digit)
  local n = 10 ^ digit
  local n1 = 10 ^ (digit - 1)
  return math.floor((num % n) / n1)
end

function grid_to_note_num(x,y)
  note_num = (grid_window.y - y + 1)*5 + grid_window.x + x - 2
  return note_num
end

local function grid_coord_to_matrix_coord(x,y)
  return {x = grid_window.x + x - 2, y = grid_window.y - y + 1}
end

local function matrix_coord_to_note_num(x,y)
  return x + y*row_interval
end

local function note_num_to_note_name (x)
  return note_table[(x % 12) + 1]
end

local function clear_table(table)
  for i in pairs(table) do
    table[i] = nil
  end
end

function table_size(table)
  count = 0
  for key, val in pairs(table) do 
    print("key: " .. key .. " val: " .. val.id)
    count = count + 1 
  end
  print("number of elements: " .. count)
  return count
end

function print_table_elements(table)
  for key, val in pairs(table) do
    print("key: " .. key .. " val: " .. val.id)
  end
end

function matrix_note(e)
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

function pattern_note(e)
  if e.starter == true then
    return
  elseif e.syncer then
    n = e.n

    print("encountered syncer event for pattern " .. n)
    if patterns[n].stoparm ~= true then
      clockid = clock.run(pattern_reset_sync, n)
      print(clockid)
      patterns[n].reset_clock_id = clockid
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

function gridredraw()
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
      bpm = bpm + delta
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
  elseif enc_control_timefactor and n == 2 then
    pattern1_timefactor = util.clamp(pattern1_timefactor + delta / 100, .0001, 100)
    pat1:set_time_factor(pattern1_timefactor)
  elseif enc_control_timefactor and n == 3 then
    pattern2_timefactor = util.clamp(pattern2_timefactor + delta / 100, .001, 100)
    pat2:set_time_factor(pattern2_timefactor)
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
    metrokey = true
  elseif n == 2 and z == 0 then
    metrokey = false
  elseif n == 3 and z == 1 and k1 then
    enc_control_timefactor = not enc_control_timefactor
  elseif n == 3 and z == 1 then
    enc_control = 1 - enc_control
    if enc_control == 0 then
      params:set("enc1",4)
      params:set("enc2",5)
      params:set("enc3",6)
    else
      params:set("enc1",3)
      params:set("enc2",1)
      params:set("enc3",2)
    end
  elseif n == 1 and z == 1 then
    k1 = true
  elseif n == 1 and z == 0 then
    k1 = false
  end
  redraw()
end

function metronome()
  while true do
    clock.sync(divnum / divdenom)
    if grid_metro_flash then
      grid_metro_level = 4
    end

    softcut.position(1,0)
    params:set("clock_tempo", bpm)
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

  
  screen.move(1,21)
  
  screen.update()
end

function note_on(note, vel)
  if nvoices < MAX_NUM_VOICES then
    engine.start(note, music.note_num_to_freq(note))
    start_screen_note(note)
    nvoices = nvoices + 1
  end
end

function note_off(note, vel)
  engine.stop(note)
  stop_screen_note(note)
  nvoices = nvoices - 1
end

function r()
  rerun()
end

function rerun()
  norns.script.load(norns.state.script)
end

function cleanup()
  pat:stop()
  pat = nil
end