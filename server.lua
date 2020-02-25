-- Copyright (c) Björn Andersson

-- Configurable items
local LISTEN_PORT = 8888    -- TCP port the server listens to
local DEFAULT_PREC = 0      -- Default precission for gauges
local DEFAULT_FREQ = 10      -- Default max frequency for gauges

local PrevLuaExportStart = LuaExportStart
local PrevLuaExportBeforeNextFrame = LuaExportBeforeNextFrame
local PrevLuaExportAfterNextFrame = LuaExportAfterNextFrame
local PrevLuaExportStop = LuaExportStop

package.path  = package.path..";.\\LuaSocket\\?.lua"
package.cpath = package.cpath..";.\\LuaSocket\\?.dll"

local socket
local server
local logf     -- log file

local selfData
local aircraft
local gauges    -- in-game gauges from GetDevice(0)
local gauge_defs = {}  -- gauge definitions from JSON file
-- gauge_defs maps gauge names and numbers to gauge definitions. The
-- defintions are loaded from aircraft specifc JSON files.
-- A gauge definition is a table with at least the following fields:
-- * arg_number: The number used in the DCS call
--   GetDevice(0):get_argument_value(arg_number)
-- * input: A range of values that is input to the visible gauge
-- * output: A range of values that is output from DCS. These values are
--   always within the range [-1.0 1.0] inclusive. The output is mapped
--   to the input through interpolation. See the interpolate() function.
-- * controller: Not used in this implementation

local devices = {} -- device name to number mapping from JSON file
local commands = {} -- command name to number mapping from JSON file
local JSON
local ready = false -- did we initialize properly?
local clients = {} -- connected clients

local CLASS_NULL = 0
local CLASS_BTN = 1
local CLASS_TUMB = 2
local CLASS_SNGBTN = 3
local CLASS_LEV = 4
local CLASS_MOVABLE_LEV = 5

local CMD_AIRCRAFT = 0
local CMD_DEV = 1 -- device command
local CMD_SUB = 2 -- subscribe to gauge value changes
local CMD_SUBIND = 3 -- subscribe to indicators
local CMD_LISTIND = 4


function LuaExportStart()
  logf = io.open(lfs.writedir().."/Logs/dcs-master.log", "w")
  logmsg("DCS Master started")
  --logmsg(lfs.currentdir())
  socket = require("socket")
  server = socket.bind("*", LISTEN_PORT)
  server:settimeout(0)
  JSON = loadfile("Scripts/JSON.lua")()
  if PrevLuaExportStart then
    PrevLuaExportStart()
  end
end

function LuaExportStop()
  socket.protect(function()
    for _, client in pairs(clients) do
      socket.try(client:close())
      clients[client] = nil
    end
  end)
  logmsg("DCS Master stopped")
  -- FIX: close logf
  if PrevExportStop then
    PrevLuaExportStop()
  end
end

function LuaExportBeforeNextFrame()
  local self = LoGetSelfData()

  if not self then
    ready = false
    return
  end

  if self.Name ~= aircraft then
    selfData = self
    aircraft = self.Name
    logmsg("Current aircraft is "..self.Name)
    read_cockpit(aircraft)
    for _, client in pairs(clients) do
      send_to_client(client, "[0, \""..aircraft.."\"]\n")
    end
    ready = true
  end
  gauges = GetDevice(0)

  for _, client in pairs(clients) do
    local data = client.socket:receive()
    if data then
      -- workaround for missing 'continue' statement in Lua:
      -- break out of 'while true' to continue 'for' loop
      while true do
        logmsg("Received: "..data)
        -- FIX: split on newline
        -- FIX: check length
        local cmd = JSON:decode(data)
        if #cmd == 0 or cmd == nil then
          logmsg("Data contains no command")
          break
        end
        local arg1 = cmd[1]
        if type(arg1) ~= "number" then
          logmsg("Command must be number")
          break
        end
        if arg1 == CMD_DEV then
          handle_device(client, cmd)
        elseif arg1 == CMD_SUB then
          handle_subscribe(client, cmd)
        elseif arg1 == CMD_SUBIND then
          handle_subscribe_indicator(client, cmd)
        elseif arg1 == CMD_LISTIND then
          handle_list_indicators(client, cmd)
        else
          logmsg(string.format("Unknown command '%d'", arg1))
        end
        break
      end
    end
  end
  if PrevLuaExportBeforeNextFrame then
    PrevLuaExportBeforeNextFrame()
  end
end

function LuaExportAfterNextFrame()
  if not ready then return end

  local client_socket = server:accept()
  if client_socket then
    local client = new_client(client_socket)
    clients[client] = client
    logmsg("Client connected")
    client_socket:settimeout(0)
    client_socket:setoption("tcp-nodelay", true)
    if aircraft then
      send_to_client(client, "[0, \""..aircraft.."\"]\n")
    end
  end
  for k, client in pairs(clients) do
    send_data(client)
  end
  if PrevLuaExportAfterNextFrame then
    PrevLuaExportAfterNextFrame()
  end
end

function string_split(s)
  local i = 1
  local list = {}
  s:gsub("[^%s]+", function(s) list[i] = s; i = i + 1 end)
  return list
end


function lines_to_list(s)
  local i = 1
  local list = {}
  s:gsub("(.-)\n", function(s) list[i] = s; i = i + 1 end)
  return list
end

function split_lines(s)
  if s:sub(-1)~="\n" then s=s.."\n" end
  return s:gmatch("(.-)\n")
end


function print_lines(t)
  for i, s in ipairs(t) do
    print(i, s)
  end
end

function logmsg(msg)
  logf:write(string.format("%8.3f %s\r\n", LoGetModelTime(), msg))
end

-- Interpolate x between the points given in xx and yy, to get y
--
-- xx and yy must be equally long lists, and xx must be in increasing order.
-- The function finds the two points in xx where x fits between and then interpolates
-- the values x to get y, the return value
--
-- points in xx where
-- x: The point we want to interpolate
-- xx: A list of x values
-- yy: The corresponding list of y values for xx
--
-- Returns: y, the interpolated value
function interpolate(x, xx, yy)
  -- FIX: handle reverse order.
  --      If the list is longer than two values and in decreasing
    --      order, then this function will give an invalid result
  if x == nil then return nil end

  local i
  -- If the list only contains a pair, then we have the points directly
  if #xx == 2 then
    i = 2
  else
    for j, v in ipairs(xx) do
      if j > 1 and x <= v then
        i = j
        break
      end
    end
  end
  return yy[i-1] + (x - xx[i-1])*((yy[i] -yy[i-1]) / (xx[i] - xx[i-1]))
end

function read_json(fn)
  local jfile, err = io.open(fn, "rb")
  if jfile == nil then
    logmsg(err)
    return nil
  end
  local json_str = jfile:read("*a")
  jfile:close()
  return JSON:decode(json_str)
end

function load_gauges(aircraft)
  local temp_gauges = read_json(lfs.writedir().."/Scripts/dcs-master/aircraft/"..aircraft.."/gauges.json")
  if not temp_gauges then
    logmsg("No gauges for "..aircraft)
    return
  end
  gauge_defs = {}
  for i, v in ipairs(temp_gauges) do
    -- index on both name and number
    gauge_defs[v.name:lower()] = v
    if v.arg_number then
      gauge_defs[v.arg_number] = v
    end
  end
  return
end

function load_devices(aircraft)
  local temp_devices = read_json(lfs.writedir().."/Scripts/dcs-master/aircraft/"..aircraft.."/devices.json")
  if not temp_devices then
    logmsg("No device names for "..aircraft)
    return
  end
  for k, v in pairs(temp_devices) do
    devices[k:lower()] = v
  end
end

function load_commands(aircraft)
  local temp_commands = read_json(lfs.writedir().."/Scripts/dcs-master/aircraft/"..aircraft.."/commands.json")
  if not temp_commands then
    logmsg("No command names for "..aircraft)
    return
  end
  for k, v in pairs(temp_commands) do
    local command = k:lower()
    commands[command] = v
    -- If there is a '.' in the name then also index on the
    -- part after that alone
    local dot = command:find(".", 1, true)
    if dot then
      commands[command:sub(dot+1)] = v
    end
  end
end


function read_cockpit(aircraft)
  load_gauges(aircraft)
  load_devices(aircraft)
  load_commands(aircraft)
end


function round(x, n)
    local n = math.pow(10, n or 0)
    local x = x * n
    if x >= 0 then
    x = math.floor(x + 0.5)
  else
    x = math.ceil(x - 0.5)
  end
    return x / n
end


-- cmd: [1, device, command, value ]
function handle_device(client, cmd)
  if #cmd ~= 4 then
    logmsg("Not enough values for command")
    return
  end
  local device = tonumber(cmd[2])
  if device == nil then
    device = devices[cmd[2]:lower()]
    if device == nil then
      logmsg("Found no device named "..cmd[2])
      return
    end
  end
  local command = tonumber(cmd[3])
  if command == nil then
    command = commands[cmd[3]:lower()]
    if command == nil then
      logmsg("Found no command named "..cmd[3])
      return
    end
  end
  local value = tonumber(cmd[4])
  if value == nil then
    logmsg("Value must be a number")
    return
  end
  if value < -1.0 or value > 1.0 then
    logmsg("Value must be withing the range [-1.0 1.0] inclusive")
    return
  end
  logmsg("Setting "..device.."."..command.." to "..value)
  GetDevice(device):performClickableAction(command, value)
end


-- client:
-- cmd: [ 2, gauge_name, id, prec, freq ]
--     prec and freq and option
-- FIX: allow list of gauges as well, i.e:
--   [ 2, [gauge_name, id, ... ], [ gauge_name ...] ]
function handle_subscribe(client, cmd)
  -- get:
  -- * frequency
  -- * precission
  -- * own ID
  local opt_id
  local opt_prec = DEFAULT_PREC
  local opt_freq = DEFAULT_FREQ

  if cmd[2] == nil then
    logmsg("No gauge argument found")
    return
  end
  local gauge_name = tonumber(cmd[2])
  if gauge_name == nil then
    gauge_name = cmd[2]:lower()
  end
  local gauge = gauge_defs[gauge_name]
  if gauge == nil then
    logmsg("Found no gauge named "..gauge_name)
    local n = tonumber(gauge_name)
    -- Dynamically create a gaauge with a one to one mapping
    if n == nil then
      return
    end
    gauge = {}
    gauge.arg_number = n
    gauge.input = {-1.0, 1.0}
    gauge.output = {-1.0, 1.0}
    gauge_defs[n] = gauge
    logmsg("Dynamically created gauge "..n)
  end
  if gauge.arg_number == nil then
    logmsg("No arg_number for arg "..gauge_name)
    return
  end
  local opt_id = tonumber(cmd[3])
  if #cmd > 3 then
    opt_prec = tonumber(cmd[4])
    if #cmd > 4 then
      opt_freq = tonumber(cmd[5])
      if opt_freq == 0 then
        client.subscribed_gauges[gauge.arg_number] = nil
        logmsg("Unsubscribing from "..gauge_name)
        return
      end
    end
  end
  -- local options = cmd[4]
  -- if options then
  --   if options.f then
  --     opt_freq = tonumber(options.f)
  --   end
  --   if options.p then
  --     opt_prec = tonumber(options.p)
  --   end
  --   if opt_freq == 0 then
  --     client.subscribed_gauges[gauge.arg_number] = nil
  --     logmsg("Unsubscribing from "..gauge_name)
  --     return
  --   end
  -- end
  logmsg("Subscribing to "..gauge_name)
  client.subscribed_gauges[gauge.arg_number] = {
    gauge = gauge,
    precission = opt_prec,
    id = opt_id,
    period = 1/opt_freq
  }
end

-- client:
-- cmd: [3, indicator_id, indicator_name, id]
function handle_subscribe_indicator(client, cmd)
  if cmd[2] == nil then
    logmsg("No indicator ID given")
    return
  end
  local indicator_id = tonumber(cmd[2])
  -- FIX: look up indicator names
  if indicator_id == nil then
    logmsg("Indicator ID must be a number")
    return
  end
  if cmd[3] == nil then
    logmsg("No indicator name given")
    return
  end
  local indicator_name = cmd[3]:lower()
  if cmd[4] == nil then
    logmsg("No own ID given")
    return
  end
  local own_id = tonumber(cmd[4])

  if client.subscribed_indicators[indicator_id] == nil then
    client.subscribed_indicators[indicator_id] = {}
  end
  client.subscribed_indicators[indicator_id][indicator_name] = {
    id = own_id
  }
end

SEP = "-----------------------------------------"

function get_indicators(id)
  logmsg("Getting indicator "..id)
  local s = list_indication(id)
  local err = false
  if not s then
    return nil
  end
  local cur_table = {}
  local tables = { cur_table }
  local strlist = lines_to_list(s)
  if #strlist == 0 then
    return nil
  end
  local i = 1
  repeat
    if strlist[i] == SEP then
      i = i + 1
      local name = strlist[i]
      i = i + 1
      local value = {}
      cur_table[name] = value
      while i <= #strlist and strlist[i] ~= SEP and strlist[i] ~= "}" and strlist[i] ~= "children are {" do
        value[#value+1] = strlist[i]
        i = i + 1
      end
      if strlist[i] == "children are {" then
        new_table = {}
        tables[#tables+1] = new_table
        value[#value+1] = new_table
        cur_table = new_table
         i = i + 1
      end
    elseif strlist[i] == "}" then
      tables[#tables] = nil
      cur_table = tables[#tables]
      i = i + 1
    else
      err = true
      logmsg("Unexpected output: "..strlist[i])
      i = i + 1
    end
  until i > #strlist
  if err then
    logmsg(s)
  end
  return cur_table
end

function get_all_indicators()
  local t = {}
  local i = 1
  logmsg("Getting all indicators")
  local indicators
  while true do
    indicators = get_indicators(i)
    if indicators then
      t[tostring(i)] = indicators
    else
      return t
    end
    i = i + 1
  end
end

function handle_list_indicators(client, cmd)
  local indicator_id
  if cmd[2] ~= nil then
    indicator_id = tonumber(cmd[2])
    if indicator_id == nil then
      logmsg("Indicator ID must be a number")
      return
    end
  end
  local indicators
  if indicator_id then
    indicators = get_indicators(indicator_id)
  else
    indicators = get_all_indicators()
    logmsg("Got "..#indicators.." indicators")
  end
  if indicators then
    send_to_client(client, JSON:encode(indicators).."\n")
  end
end

function send_json(client, gauges)
  local s = "["..CMD_SUB
  for _, gauge in pairs(gauges) do
    local fmt = "%s,[%s,%."..gauge.precission.."f]"
    s = fmt:format(s, gauge.id, gauge.gauge_value)
  end
  s = s.."]\n"
  send_to_client(client, s)
end


function send_indicators_json(client, indicators)
  local s = "["..CMD_SUBIND
  for _, ind in pairs(indicators) do
    s = string.format("%s,[%s,\"%s\"]", s, ind.id, ind.value)
  end
  s = s.."]\n"
  send_to_client(client, s)
end

function send_speed(client)
  -- LoGetADIPitchBankYaw()   -- (args - 0, results - 3 (rad))
  -- LoGetAngleOfAttack() -- (args - 0, results - 1 (rad))
  -- LoGetAccelerationUnits() -- (args - 0, results - table {x = Nx,y = NY,z = NZ} 1 (G))
  -- LoGetVerticalVelocity()  -- (args - 0, results - 1(m/s))

  local accel = LoGetAccelerationUnits() -- {x = Nx,y = NY,z = NZ} 1 (G)
  local vector_vel = LoGetVectorVelocity() -- { x, y, z } vector of self velocity (world axis)
  local angular_vel = LoGetAngularVelocity() -- { x, y, z } angular velocity euler angles , rad per sec
  --> calculate angular accelleration
  -- local s = string.format("[%f, %f, %f] [%f, %f, %f] [%f, %f, %f]\n",
  --   vector_vel.x, vector_vel.y, vector_vel.z,
  --   angular_vel.x, angular_vel.y, angular_vel.z,
  --   accel.x, accel.y, accel.z])
  local s = string.format("[%f, %f, %f]\n",
    accel.x, accel.y, accel.z)
  send_to_client(client, s)
end


function send_data(client)
  local send_gauges = {}
  local t = LoGetModelTime()
  for arg_number, gauge in pairs(client.subscribed_gauges) do
    if not gauge.send_time or t > gauge.send_time + gauge.period then
      local output = gauges:get_argument_value(arg_number)
      input = round(interpolate(output, gauge.gauge.output, gauge.gauge.input), gauge.precission)
      if gauge.gauge_value ~= input then
        gauge.gauge_value = input
        gauge.send_time = t
        send_gauges[#send_gauges+1] = gauge
      end
    end
  end
  if #send_gauges > 0 then
    -- FIX: optional CBOR
    send_json(client, send_gauges)
  end
  local send_indicators = {}
  for indicator_id, indicator_names in pairs(client.subscribed_indicators) do
    local data = list_indication(indicator_id)
    if data then
      local datalines = lines_to_list(data)
      for i = 1, #datalines do
        local ind = datalines[i]
        local sub_ind = indicator_names[ind:lower()]
        if sub_ind then
          i = i + 1
          ind_value = datalines[i]
          if ind_value ~= sub_ind.value then
            sub_ind.value = ind_value
            send_indicators[#send_indicators+1] = sub_ind
          end
        end
      end
    end
  end
  if #send_indicators > 0 then
    send_indicators_json(client, send_indicators)
  end
  -- send_speed(client)
end


function send_to_client(client, s)
  if not client then
    return
  end

  local res, errmsg, lastbyte = client.socket:send(s)
  if res == nil then
    logmsg("Client error: "..errmsg)
    clients[client] = nil
  end

end

function new_client(socket)
  client = {
    socket = socket,
    subscribed_gauges = {},
    subscribed_indicators = {}
  }
  return client
end