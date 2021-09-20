local tab = require 'tabutil'
local pattern_time = require 'pattern_time'
local music = require 'musicutil'

local polysub = include 'we/lib/polysub'

local g = grid.connect()

grid_led = 1

local currently_playing = {}
local enc_control = 0
pressed_notes = {}
local held_notes = {}
local holding = false
local pattern_1_led_level = 8
local pattern_2_led_level = 6
local holding_led_pulse_level = 4

local visual_refresh_rate = 30
local screen_refresh_metro

local MAX_NUM_VOICES = 16

local options = {
  same_note_behavior = {"retrigger", "detuned", "ignore"}
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
local k3 = false
local altkey = false
local file = _path.dust.."audio/metro-tick.wav"

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

local function grid_led_clear()
  for x=1,16 do
    for y=1,8 do
      grid_led[x][y].level = 0
      grid_led[x][y].dirty = true
    end
  end
end

local function note_hash(x,y)
  return y*40 + x
end

function init()
  m = midi.connect()
  m.event = midi_event

  pat = pattern_time.new()
  pat.process = grid_note_trans

  params:add_option("enc1","enc1", {"shape","timbre","noise","cut","ampatk","amprel"}, 4)
  params:add_option("enc2","enc2", {"shape","timbre","noise","cut","ampatk","amprel"}, 5)
  params:add_option("enc3","enc3", {"shape","timbre","noise","cut","ampatk", "amprel"}, 6)
  params:add_option("same_note_behavior", "same note behavior", options.same_note_behavior, 1)

  params:add_separator()

  polysub:params()

  params:add_separator()
  
  engine.stopAll()

  params:bang()

  grid_led = grid_led_array_init()

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

local function create_fixed_pulse(x, y, pmin, pmax, rate)
  pulse = {x = x, y = y, pmin = pmin, pmax = pmax, rate = rate, current = pmin, dir = 1, mode = "fixed"}
  pulse.frames_per_step = math.floor(0.5 + rate * visual_refresh_rate / (2*(pmax - pmin)))
  pulse.frametrack = pulse.frames_per_step

  id = y*16 + x
  lighting_over_time.fixed[id] = pulse

  return pulse
end

local function create_mod_pulse(range, rate, note_id)
  pulse = {range = range, current = 0, dir = 1, mode = "mod", note_id = note_id}
  pulse.frames_per_step = math.floor(0.5 + rate * visual_refresh_rate / (2*(range)))
  pulse.frametrack = pulse.frames_per_step

  lighting_over_time.mod[note_id] = pulse

  return pulse
end

function g.key(x, y, z)
  if x == 1 then
    if z == 1 then
      if y == 8 and not holding then
        for id, e in pairs(pressed_notes) do
          e.pulser = create_mod_pulse(holding_led_pulse_level, .75, id)
          held_notes[id] = e
        end
        create_fixed_pulse(x, y, 2, 8, .75)
        holding = true
      elseif y == 8 and holding then
        for id in pairs(held_notes) do
          held_notes[id] = nil
          engine.stop(id)
          currently_playing[id] = nil
          nvoices = nvoices - 1
        end
        id = y*16 + x
        lighting_over_time.fixed[id] = nil
        --pulsing[id] = nil
        --g:led(x, y, 0)
        holding = false
      elseif y == 3 and pat.rec == 0 then
        mode_transpose = 0
        trans.x = 5
        trans.y = 5
        pat:stop()
        engine.stopAll()
        pat:clear()
        pat:rec_start()
      elseif y == 3 and pat.rec == 1 then
        pat:rec_stop()
        if pat.count > 0 then
          root.x = pat.event[1].x 
          root.y = pat.event[1].y 
          trans.x = root.x
          trans.y = root.y
          pat:start()
        end
      elseif y == 4 and pat.play == 0 and pat.count > 0 then
        if pat.rec == 1 then
          pat:rec_stop()
        end
        pat:start()
      elseif y == 4 and pat.play == 1 then
        pat:stop()
        engine.stopAll()
        nvoices = 0
      elseif y == 5 then
        mode_transpose = 1 - mode_transpose
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
      elseif y == 7 then
        altkey = true
      end
    elseif z == 0 then
      if y == 7 then
        altkey = false
      end
    end
  else
    local e = {}
    e.id = note_hash(grid_window.x + x - 2, grid_window.y - y + 1) * 100 + sources.pressed * 10 -- 2nd to last digit of ID specifies source
    e.x = grid_window.x + x - 2
    e.y = grid_window.y - y + 1
    e.state = z
    pat:watch(e)
    if z == 1 then
      matrix_note(e)
      e.x_transpose_since_press = 0
      e.y_transpose_since_press = 0
      pressed_notes[e.id] = e
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

local function note_id_to_info(id)
  id = id .. ""
  n = id:sub(1,-3)
  y = math.floor(n/40)
  x = n - y*40
  return {x = x, y = y, source = id:sub(-2,-2)}
end

function lighting_update_handler()
  grid_led_clear()
  -- light c notes
  for x = 2,16,1 do
    for y = 1,8,1 do
      if grid_to_note_num(x,y) == 60 then
        grid_led_set(x,y,8)
      elseif grid_to_note_num(x,y) % 12 == 0 then
        grid_led_set(x,y,8)
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
      elseif obj.current == obj.pmax then
        obj.dir = -1        
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
      elseif obj.current == obj.range then
        obj.dir = -1
      end

      obj.frametrack = obj.frames_per_step
    end    
  end
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
  -- if held_notes[e.id] ~= nil then
  --   if params:string("same_note_behavior") == "ignore" then
  --     return
  -- end
  
  -- local note_num = matrix_coord_to_note_num(e.x, e.y)
  -- if e.state > 0 then
  --   if nvoices < MAX_NUM_VOICES then
  --     id = e.id .. ""
  --     id = id:sub(1,-3)
  --     detune = 0
  --     for id2,e2 in pairs(currently_playing) do
  --       id2 = id2 .. ""
  --       id2 = id2:sub(1,-3)
  --       if id == id2 then
  --       if params:string("same_note_behavior") == "ignore" then
  --         return
  --       elseif params:string("same_note_behavior") == "detuned" then
  --         detune = math.random(-200, 200) / 100

  --         if currently_playing[e.id] ~= nil then
  --           while currently_playing[e.id] ~= nil do
  --             e.id = e.id + 1
  --           end

  --       end
  --     start_note(e.id, note_num, detune)
  --     currently_playing[e.id] = e
  --     nvoices = nvoices + 1
  --   else
  --     print("maximum voices reached")
  --   end
  -- else
  --   if currently_playing[e.id] ~= nil and held_notes[e.id] == nil then
  --     engine.stop(e.id)
  --     currently_playing[e.id] = nil
  --     nvoices = nvoices - 1
  --   end
  -- end
  -- --gridredraw()
  if held_notes[e.id] ~= nil then
    --return
  end
  
  local note_num = matrix_coord_to_note_num(e.x, e.y)
  if e.state > 0 then
    if nvoices < MAX_NUM_VOICES then
      start_note(e.id, note_num)
      currently_playing[e.id] = e
      nvoices = nvoices + 1
    end
  else
    if currently_playing[e.id] ~= nil and held_notes[e.id] == nil then
      engine.stop(e.id)
      currently_playing[e.id] = nil
      nvoices = nvoices - 1
    end
  end
  --gridredraw()
end

function grid_note_pattern(e)
  local id = e.id .. "p"
  local note = grid_to_note_num(e.x, e.y) - offset + e.offset
  if e.state > 0 then
    if nvoices < MAX_NUM_VOICES then
      start_note(id, note)
      currently_playing[id] = {x = e.x, y = e.y, offset = e.offset}
      nvoices = nvoices + 1
    end
  else
    stop_note(id)
    currently_playing[id] = nil
    nvoices = nvoices - 1
  end
  --gridredraw()
end

function gridredraw()
  g:all(0)

  for x=1,16 do 
    for y=1,8 do
      if true then
      --if grid_led[x][y].dirty then
        g:led(x,y,grid_led[x][y].level)
      end
    end
  end

  g:refresh()
end

function enc(n,delta)
  if metrokey and k3 then
    if n == 1 then
      metrolevel = util.clamp(metrolevel + delta/10, 0, 30)
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
  elseif k3 then
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
    metrokey = true
  elseif n == 2 and z == 0 then
    metrokey = false
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
    k3 = true
  elseif n == 1 and z == 0 then
    k3 = false
  end
  redraw()
end

function metronome()
  while true do
    clock.sync(divnum / divdenom)
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