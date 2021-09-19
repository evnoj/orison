-- earthsea: pattern instrument
-- 1.1.0 @tehn
-- llllllll.co/t/21349
--
-- subtractive polysynth
-- controlled by midi or grid
--
-- grid pattern player:
-- 1 1 record toggle
-- 1 2 play toggle
-- 1 8 transpose mode
local SCALE_BRIGHTNESS = 2
local OCTAVE_MARKER_BRIGHTNESS = 5
local BRIGHTNESS = 14
local OVERSIZE_CHORD_WIDTH = 5.5

local NOTES = { 'A', 'A#', 'B', 'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#' }

local GUIDES_OPTIONS = { 'none', 'octave markers', 'full scale' }
local VOICING_OPTIONS = { 'closed only', 'basic', 'expanded' }

local CLOSED_VOICINGS = {
  closed = { 0, 0, 0, 0 }
}

local BASIC_VOICINGS = {
  closed = { 0, 0, 0, 0 },
  first_inversion = { 1, 0, 0, 0 },
  second_inversion = { 1, 1, 0, 0 },
  third_inversion = { 1, 1, 1, 0 }
}

local EXPANDED_VOICINGS = {
  closed = { 0, 0, 0, 0 },
  first_inversion = { 1, 0, 0, 0 },
  second_inversion = { 1, 1, 0, 0 },
  third_inversion = { 1, 1, 1, 0 },
  drop2 = { 0, -1, 0, 0 },
  drop3 = { 0, 0, -1, 0 },
  drop3_first_inversion = { 1, 0, -1, 0 },
  drop4_first_inversion = { 1, 0, 0, -1 },
  drop4_second_inversion = { 1, 1, 0, -1 },
  raise2 = { 0, 1, 0, 0 },
  raise2_3 = { 0, 1, 1, 0 },
  raise2_3_first_inversion = { 1, 0, 1, 0 },
  spread = { -1, 0, 0, 1 },
  spread_first_inversion = { 2, -1, 0, 0 },
  spread_second_inversion = { 1, 2, -1, 0 },
  spread_third_inversion = { 1, 1, 2, -1 },
}

local SCALE_OPTIONS = { 
  'chromatic', 
  'major', 
  'natural minor', 
  'harmonic minor', 
  'melodic minor', 
  'whole tone', 
  'octatonic', 
  'pentatonic',
  'blues' 
}

local SCALE_DEFINITIONS = {
  chromatic = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
  major = { 0, 2, 4, 5, 7, 9, 11 },
  ['natural minor'] = { 0, 2, 3, 5, 7, 8, 10 },
  ['harmonic minor'] = { 0, 2, 3, 5, 7, 8, 11 },
  ['melodic minor'] = { 0, 2, 3, 5, 7, 9, 11 },
  ['whole tone'] = { 0, 2, 4, 6, 8, 10 },
  octatonic = { 0, 1, 3, 4, 6, 7, 9, 10 },
  pentatonic = { 0, 2, 5, 7, 9 },
  blues = { 0, 2, 3, 4, 7, 9 },
}

local CHORDS = {
  maj = { 0, 4, 7 },
  min = { 0, 3, 7 },
  dim = { 0, 3, 6 },
  aug = { 0, 4, 8 },
  sus2 = { 0, 2, 7 },
  sus4 = { 0, 5, 7 },
  maj7 = { 0, 4, 7, 11 },
  min7 = { 0, 3, 7, 10 },
  dom7 = { 0, 4, 7, 10 },
  dim7 = { 0, 3, 6, 9 },
  -- halfdim = { 0, 3, 6, 10 },
  -- sus2maj7 = { 0, 2, 7, 11 },
  -- sus4min7 = { 0, 5, 7, 10 },
  -- aug7 = { 0, 4, 8, 10 }
}

local dark_mode = false
local chord_description = ''
local state = 'free'

local tab = require 'tabutil'
local pattern_time = require 'pattern_time'
local music = require 'musicutil'


local polysub = include 'we/lib/polysub'

local g = grid.connect()

local currently_playing = {}
local offset = 43
local enc_control = 0
local pressed_notes = {}
local held_notes = {}
local holding = false
grid_led = 1
local pattern_1_led_level = 8
local pattern_2_led_level = 6
local holding_led_pulse_level = 4

local screen_framerate = 30
local screen_refresh_metro

local MAX_NUM_VOICES = 16

local options = {
  OUTPUT = {"audio", "crow out 1+2", "crow ii JF"}
}

engine.name = 'PolySub'

-- pythagorean minor/major, kinda
local ratios = { 1, 9/8, 6/5, 5/4, 4/3, 3/2, 27/16, 16/9 }
local base = 27.5 -- low A

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
--local pulsing = {}
local file = _path.dust.."audio/metro-tick.wav"
local note_table = {"c", "csharp/dflat", "d", "dsharp/eflat", "e", "f", "fsharp/gflat", "g", "gsharp/aflat", "a", "asharp/bflat", "b"}
local flat_note_table = {"c", "dflat", "d", "eflat", "e", "f", "gflat", "g", "aflat", "a", "bflat", "b"}
local sharp_note_table = {"c", "csharp", "d", "dsharp", "e", "f", "fsharp", "g", "gsharp", "a", "asharp", "b"}
local SCALE_DEFINITIONS = {
  chromatic = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
  major = { 0, 2, 4, 5, 7, 9, 11 },
  ['natural minor'] = { 0, 2, 3, 5, 7, 8, 10 },
  ['harmonic minor'] = { 0, 2, 3, 5, 7, 8, 11 },
  ['melodic minor'] = { 0, 2, 3, 5, 7, 9, 11 },
  ['whole tone'] = { 0, 2, 4, 6, 8, 10 },
  octatonic = { 0, 1, 3, 4, 6, 7, 9, 10 },
  pentatonic = { 0, 2, 5, 7, 9 },
  blues = { 0, 2, 3, 4, 7, 9 },
}

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

  params:add_separator()

  polysub:params()

  params:add_separator()
  
  params:add{type = "option", id = "output", name = "output",
    options = options.OUTPUT,
    action = function(value)
      engine.stopAll()
      if value == 2 then crow.output[2].action = "{to(5,0),to(0,0.25)}"
      elseif value == 3 then
        crow.ii.pullup(true)
        crow.ii.jf.mode(1)
      end
    end
  }
  
  engine.stopAll()

  params:bang()

  grid_led = grid_led_array_init()

  --if g then gridredraw() end

  screengrid_refresh_metro = metro.init()
  screengrid_refresh_metro.event = function(stage)
    lighting_update_handler()
    redraw()
    gridredraw()
  end
  screengrid_refresh_metro:start(1 / screen_framerate)
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

local function create_fixed_pulse(x, y, pmin, pmax, rate, ptype)
  pulse = {x = x, y = y, pmin = pmin, pmax = pmax, rate = rate, current = pmin, dir = 1, mode = "fixed"}
  pulse.frames_per_step = math.floor(1 / rate * screen_framerate / (2*(pmax - pmin)))
  pulse.frametrack = pulse.frames_per_step

  id = y*16 + x
  lighting_over_time.fixed[id] = pulse

  return pulse
end

local function create_mod_pulse(range, rate, note_id)
  pulse = {range = range, current = 0, dir = 1, mode = "mod", note_hash = note_hash}
  pulse.frames_per_step = math.floor(1 / rate * screen_framerate / (2*(range)))
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
        --pulsing[x*8 + y] = fixed_pulse_constructor(x, y, 2, 8, .75)
        --lighting_over_time[] = fixed_pulse_constructor(x, y, 2, 8, .75))
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
          root.x = pat.event[1].x + offset
          root.y = pat.event[1].y + offset
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
      elseif y == 2 then
        grid_window.y = grid_window.y - 1
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
    e.id = note_hash(grid_window.x + x - 2, grid_window.y - y + 1) * 10 + 1
    e.x = grid_window.x + x - 2
    e.y = grid_window.y - y + 1
    e.state = z
    pat:watch(e)
    grid_note(e)
    if z == 1 then
      e.grid_x = x
      e.grid_y = y
      pressed_notes[e.id] = e
    else
      grid_note(e)
      pressed_notes[e.id] = nil
      for id, e2 in pairs(pressed_notes) do
        if x == e2.grid_x and y == e2.grid_y then
          e2.state = 0
          grid_note(e2)
          pressed_notes.id = nil
        end
      end
    end
  end
  gridredraw()
end

local function note_id_to_info(id)
  id = id .. ""
  n = id:sub(1,-2)
  y = math.floor(n/40)
  x = n - y*40
  return {x = x, y = y, source = id:sub(-1)}
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
      print(e.pulser.current)
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

local function start_note(id, note)
  if params:get("output") == 1 then
    engine.start(id, music.note_num_to_freq(note))
  elseif params:get("output") == 2 then
    crow.output[1].volts = note/12
    crow.output[2].execute()
  elseif params:get("output") == 3 then
    crow.ii.jf.play_note(note/12,5)
  end
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

function grid_note(e)
  if held_notes[e.id] ~= nil then
    return
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
--[[
  g:all(0)
  
  -- light c notes
  for x = 2,16,1 do
    for y = 1,8,1 do
      if grid_to_note_num(x,y) == 60 then
        g:led(x,y,8)
      elseif grid_to_note_num(x,y) % 12 == 0 then
        g:led(x,y,5)
      end
    end
  end
  
  -- light transpose keys
  g:led(1, 1, math.floor((grid_window.y - 7) / 2))
  g:led(1, 2, math.floor((21 - grid_window.y) / 2))
  
  --g:led(1,1,2 + pat.rec * 10)
  --g:led(1,2,2 + pat.play * 10)
  --g:led(1,8,2 + mode_transpose * 10)
  
  
  for i, e in pairs(pulsing) do
    if e.current == e.pmin then
      e.dir = 1
    elseif e.current == e.pmax then
      e.dir = -1
    end
    e.current = e.current + e.rate * e.dir
    g:led(e.x, e.y, e.current)
  end
  

  for i,e in pairs(currently_playing) do
    if (e.x + e.y*5) % 12 ~= 0 then
      g:led(e.x - grid_window.x + 2, grid_window.y - e.y + 1, 1)
    end
  end

  g:refresh()
  --]]
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

function midi_event(data)
  if #data == 0 then return end
  local msg = midi.to_msg(data)

  -- Note off
  if msg.type == "note_off" then
    note_off(msg.note)

    -- Note on
  elseif msg.type == "note_on" then
    note_on(msg.note, msg.vel / 127)

--[[
    -- Key pressure
  elseif msg.type == "key_pressure" then
    set_key_pressure(msg.note, msg.val / 127)

    -- Channel pressure
  elseif msg.type == "channel_pressure" then
    set_channel_pressure(msg.val / 127)

    -- Pitch bend
  elseif msg.type == "pitchbend" then
    local bend_st = (util.round(msg.val / 2)) / 8192 * 2 -1 -- Convert to -1 to 1
    local bend_range = params:get("bend_range")
    set_pitch_bend(bend_st * bend_range)

  ]]--
  end

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

--[[
local function options_text1()
  local hands_text = params:get('num_hands') .. (params:get('num_hands') == 1 and ' hand' or' hands')
  local voicing_text = params:string('voicings') .. ' voicings'
  return hands_text .. ', ' .. voicing_text
end

local function redraw_screen_free()
  screen.level(15)
  screen.font_size(13)
  screen.move(64, 28)
  screen.text_center(chord_description)

  screen.level(5)
  screen.font_face(1)
  screen.font_size(8)
  screen.move(64, 63)
  screen.text_center('K3 to ' .. (dark_mode and 'show' or 'hide') .. ' chords')
end

local function redraw_screen()
  screen.clear()
  screen.aa(1)
  screen.font_face(24)
  
  if state == 'free' then
    redraw_screen_free()
  elseif state == 'game_loading' then
    redraw_screen_game_loading()
  elseif state == 'game_in_progress' then
    redraw_screen_game_in_progress()
  elseif state == 'game_over' then
    redraw_screen_game_over()
  end
  
  screen.update()
  
  -- restore font defaults for compatibility with settings page
  screen.font_size(8)
  screen.font_face(1)
end

local function fresh_grid(b)
  b = b or 0
  return {
    {b, b, b, b, b, b, b, b, b, b, b, b, b, b, b, b},
    {b, b, b, b, b, b, b, b, b, b, b, b, b, b, b, b},
    {b, b, b, b, b, b, b, b, b, b, b, b, b, b, b, b},
    {b, b, b, b, b, b, b, b, b, b, b, b, b, b, b, b},
    {b, b, b, b, b, b, b, b, b, b, b, b, b, b, b, b},
    {b, b, b, b, b, b, b, b, b, b, b, b, b, b, b, b},
    {b, b, b, b, b, b, b, b, b, b, b, b, b, b, b, b},
    {b, b, b, b, b, b, b, b, b, b, b, b, b, b, b, b},
  }
end

local held_keys = fresh_grid()
local enabled_coords = fresh_grid()

local function getHzET(note)
  return 55*2^(note/12)
end

local function note_value(x, y)
  return ((7 - y) * 5) + x
end

local function coord_id(x, y)
  return (x * 8) + y
end

local function toggle_note(x, y, on)
  local note = note_value(x, y)
  
  if on > 0 then
    engine.start(coord_id(x, y), getHzET(note))
  else
    engine.stop(coord_id(x, y))
  end
end

local function coords_to_note(x, y)
  local note = note_value(x, y)
  return NOTES[(note % 12) + 1]
end

local function remove_doubled_notes(grid)
  local enabled_notes = {}
  
  for x = 1, g.cols do
    for y = 1, g.rows do
      if grid[y][x] > 0 then
        if enabled_notes[note_value(x, y)] then
          grid[y][x] = 0
        end
        
        enabled_notes[note_value(x, y)] = true
      end
    end
  end
end

local function table_length(obj)
  local count = 0
  for _ in pairs(obj) do count = count + 1 end
  return count
end

local function random_chord()
  local chord_number = math.random(table_length(CHORDS))
  local num = 0
  
  for name, def in pairs(CHORDS) do
    num = num + 1
    if num == chord_number then
      return { chord_name = name, chord_def = def }
    end
  end
end

local function random_voicing()
  local voicings = CLOSED_VOICINGS
  if params:string('voicings') == 'expanded' then
    voicings = EXPANDED_VOICINGS
  elseif params:string('voicings') == 'basic' then
    voicings = BASIC_VOICINGS
  end
  
  local voicing_number = math.random(table_length(voicings))
  local num = 0
  
  for name, def in pairs(voicings) do
    num = num + 1
    if num == voicing_number then
      return { voicing_name = name, voicing_def = def }
    end
  end
end

local function voice_chord_def(chord_def, voicing_def)
  local voiced_chord_def = {}
  
  for idx, semitone_interval in pairs(chord_def) do
    table.insert(voiced_chord_def, semitone_interval + (voicing_def[idx] * 12))
  end
  table.sort(voiced_chord_def)
  
  return voiced_chord_def
end

local function in_grid(x, y)
  return x >= 1 and x <= g.cols and y >= 1 and y <= g.rows
end

local function deep_copy(obj)
  if type(obj) ~= 'table' then return obj end
  local res = {}
  for k, v in pairs(obj) do res[deep_copy(k)] = deep_copy(v) end
  return res
end

local function position_options(root, interval)
  local options = {}
  
  local option = { x = root.x + interval, y = root.y }
  while option.x <= g.cols do
    if in_grid(option.x, option.y) then
      table.insert(options, deep_copy(option))
    end
    
    option.x = option.x + 5
    option.y = option.y + 1
  end
  
  option = { x = root.x + interval - 5, y = root.y - 1 }
  while option.x >= 1 do
    if in_grid(option.x, option.y) then
      table.insert(options, deep_copy(option))
    end
    
    option.x = option.x - 5
    option.y = option.y - 1
  end
  
  return options
end

local function coord_distance(coord1, coord2)
  return (((coord1.x - coord2.x) ^ 2) + ((coord1.y - coord2.y) ^ 2)) ^ 0.5
end

local function max_distance(chord_shape)
  local max_dist = 0
  
  for coord_idx1 = 1, #chord_shape - 1 do
    for coord_idx2 = coord_idx1 + 1, #chord_shape do
      local coord1 = chord_shape[coord_idx1]
      local coord2 = chord_shape[coord_idx2]
      max_dist = math.max(max_dist, coord_distance(coord1, coord2))
    end
  end
  
  return max_dist
end

-- TODO: this could maybe be improved by just generating all
-- the possibilities for a given voiced chord def and just comparing
-- them all at once instead of one at a time
-- could compare by max distance or could first constrain by RMS distance
-- from root, or some combination
local function chord_shape(root, chord_def, voicing_def)
  local voiced_chord_def = voice_chord_def(chord_def, voicing_def)
  -- we artificially place the root in the shape to begin with so that we can
  -- start as close as possible, but will remove it later
  local shape = { root }
  local pass = 1

  for _, semitone_interval in pairs(voiced_chord_def) do
    -- see comment above
    if pass == 2 then
      table.remove(shape, 1)
    end
    pass = pass + 1
    
    local options = position_options(root, semitone_interval)
    local best_option = table.remove(options, 1)
    if best_option == nil then return nil end
    local best_shape = deep_copy(shape)
    table.insert(best_shape, best_option)
    
    while #options > 0 do
      local potential_option = table.remove(options, 1)
      local potential_shape = deep_copy(shape)
      table.insert(potential_shape, potential_option)
      
      local best_distance = max_distance(best_shape)
      local potential_distance = max_distance(potential_shape)
      
      if best_distance == potential_distance then
        local shapes = { best_shape, potential_shape }
        best_shape = shapes[math.random(2)]
      elseif best_distance < potential_distance then
        best_shape = best_shape
      else
        best_shape = potential_shape
      end
    end
    
    shape = best_shape
  end
  
  if max_distance(shape) > OVERSIZE_CHORD_WIDTH then
    return nil
  end
  
  return shape
end

local function scale_definition()
  return SCALE_DEFINITIONS[params:string('scale_types')]
end

local function value_index(tab, value)
  for k, v in pairs(tab) do
    if v == value then
      return k
    end
  end
  
  return nil
end

local function in_scale(note)
  local root_scale_index = value_index(NOTES, params:string('scale_keys'))
  for _, interval in pairs(scale_definition()) do
    local scale_index = ((root_scale_index + interval - 1) % 12) + 1
    
    local scale_note = NOTES[scale_index]
    if note == scale_note then
      return true
    end
  end
  
  return false
end

local function combine_grids(first_grid, second_grid)
  local result = fresh_grid()
  
  for x = 1, g.cols do
    for y = 1, g.rows do
      if first_grid[y][x] > 0 or second_grid[y][x] > 0 then
        result[y][x] = 1
      end
    end
  end
  
  return result
end

local function num_active(grid)
  local count = 0
  for x = 1, g.cols do
    for y = 1, g.rows do
      if grid[y][x] ~= 0 then
        count = count + 1
      end
    end
  end
  
  return count
end

local function activate_chords()
  if num_active(enabled_coords) > 0 then
    return
  end
  
  local potential_enabled_coords = fresh_grid()
  chord_description = ''

  local chords_generated = 0
  while chords_generated < params:get('num_hands') do
    local potential_enabled_coords = fresh_grid()
    local potential_chord = random_chord()
    local potential_voicing = random_voicing()
    local valid_chord = true
    
    -- we go slightly beyond the boundaries of the grid so that even with voicings
    -- we can get all chord shapes all throughout the grid
    local root = { x = math.random(-1, g.cols + 2), y = math.random(-1, g.rows + 2) }
    local shape = chord_shape(
      root,
      potential_chord.chord_def, 
      potential_voicing.voicing_def
    )
    
    if shape == nil then
      valid_chord = false
    else
      for _, coord in pairs(shape) do
        local x = coord.x
        local y = coord.y
        
        if (not in_scale(coords_to_note(x, y))) or (not in_grid(x, y)) then
          valid_chord = false
          break
        end
        
        potential_enabled_coords[y][x] = 1
      end
    end
    
    if valid_chord then
      chords_generated = chords_generated + 1
      enabled_coords = combine_grids(enabled_coords, potential_enabled_coords)
      
      if chord_description ~= '' then
        chord_description = chord_description .. ' / '
      end
      
      chord_description = chord_description .. (coords_to_note(root.x, root.y) .. potential_chord.chord_name)
    end
  end
  
  remove_doubled_notes(enabled_coords)
  redraw_screen()
end

local function dark_mode_correct_keys_held()
  local held_notes = {}
  local enabled_notes = {}

  for x = 1, g.cols do
    for y = 1, g.rows do
      if held_keys[y][x] ~= 0 then
        held_notes[coords_to_note(x, y)] = true
      end
      
      if enabled_coords[y][x] ~= 0 then
        enabled_notes[coords_to_note(x, y)] = true
      end
    end
  end
  
  for held_note, _ in pairs(held_notes) do
    if not enabled_notes[held_note] then
      return false
    end
  end
  
  for enabled_note, _ in pairs(enabled_notes) do
    if not held_notes[enabled_note] then
      return false
    end
  end
  
  return true
end

local function light_mode_correct_keys_held()
  for x = 1, g.cols do
    for y = 1, g.rows do
      if held_keys[y][x] ~= enabled_coords[y][x] then
        return false
      end
    end
  end
  
  return true
end

local function correct_keys_held()
  if num_active(enabled_coords) == 0 then
    return false
  end
  
  if dark_mode then
    return dark_mode_correct_keys_held()
  else
    return light_mode_correct_keys_held()
  end
end

local function check_for_error(x_check, y_check)
  if dark_mode then
    local enabled_notes = {}

    for x = 1, g.cols do
      for y = 1, g.rows do
        if enabled_coords[y][x] > 0 then
          enabled_notes[coords_to_note(x, y)] = true
        end
      end
    end
    
    if not enabled_notes[coords_to_note(x_check, y_check)] then
      game_errors = game_errors + 1
    end
  else
    if enabled_coords[y_check][x_check] == 0 then
      game_errors = game_errors + 1
    end
  end
end

local function redraw_lights()
  for x = 1, g.cols do
    for y = 1, g.rows do
      local brightness = not dark_mode and enabled_coords[y][x] * BRIGHTNESS or 0

      if params:string('guides') == 'octave markers' or params:string('guides') == 'full scale' then
        if params:string('scale_keys') == coords_to_note(x, y) then
          brightness = math.max(brightness, OCTAVE_MARKER_BRIGHTNESS)
        end
      end
      
      if params:string('guides') == 'full scale' then
        if in_scale(coords_to_note(x, y)) then
          brightness = math.max(brightness, SCALE_BRIGHTNESS)
        end
      end
      
      g:led(x, y, brightness)
    end
  end
  
  g:refresh()
end

local function main_update_loop()
  activate_chords()
  redraw_lights()
  
  if correct_keys_held() then
    enabled_coords = fresh_grid()
    rounds_finished = rounds_finished + 1
  end
end

-- init

function init()
  params:add{ type = 'option', id = 'scale_keys', name = 'scale key', options = NOTES }
  params:add{ type = 'option', id = 'scale_types', name = 'scale type', options = SCALE_OPTIONS }
  params:add{ type = 'option', id = 'guides', name = 'guides', options = GUIDES_OPTIONS, default = 2 }
  params:add{ type = 'option', id = 'voicings', name = 'voicings', options = VOICING_OPTIONS, default = 2 }
  params:add{ type = 'number', id = 'num_hands', name = 'number of hands', min = 1, max = 2, default = 1 }
  params:add_separator()
  polysub:params()
  
  engine.stopAll()
  
  local main_loop = metro.init(main_update_loop, 0.1)
  main_loop:start()
end

-- norns

function key(n, z)
  if n == 3 and z == 1 then
    dark_mode = not dark_mode
  end
  
  redraw_screen()
end

function enc(n, delta)
  if n == 1 then
    mix:delta('output', delta)
  elseif n == 2 then
    params:delta('shape', delta)
  elseif n == 3 then
    params:delta('timbre', delta)
  end
end

-- grid

g.key = function(x, y, z)
  held_keys[y][x] = z
  
  if z == 1 and state == 'game_in_progress' then
    check_for_error(x, y)
  end
  
  toggle_note(x, y, z)
end
--]]