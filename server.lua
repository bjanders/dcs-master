-- Copyright (c) Björn Andersson

package.path  = package.path..";.\\LuaSocket\\?.lua"
package.cpath = package.cpath..";.\\LuaSocket\\?.dll"
  
local socket
local server
local logf 		-- log file

local aircraft
local gauges		-- in-game gauges from GetDevice(0)
local gauge_defs = {}	-- gauge definitions from JSON file
-- gauge_defs maps gauge names and numbers to gauge definitions. The
--		defintions are loaded from aircraft specifc JSON files.
-- A gauge definition is a table with at least the following fields:
-- * arg_number: The number used in the DCS call
--		GetDevice(0):get_argument_value(arg_number)
-- * input: A range of values that is input to the visible gauge
-- * output: A range of values that is output from DCS. These values are
--		always within the range [-1.0 1.0] inclusive. The output is mapped
--		to the input through interpolation. See the interpolate() function.
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


function LuaExportStart()
	logf = io.open(lfs.writedir().."/Logs/dcs-master.log", "w")
	logmsg("DCS Master started")
	local self = LoGetSelfData()
	if not self then
		logmsg("No SelfData, exiting")
		return
	end
	aircraft = self.Name
	logmsg("Current aircraft is "..self.Name)
	--logmsg(lfs.currentdir())
	socket = require("socket")
	server = socket.bind("*", 8888)
	server:settimeout(0)
	gauges = GetDevice(0)
	JSON = loadfile("Scripts/JSON.lua")()
	read_cockpit(self.Name)
	ready = true
end

function LuaExportStop()
	for _, client in pairs(clients) do
		client:close()
		clients[client] = nil
	end
	logmsg("DCS Master stopped")
end

function LuaExportBeforeNextFrame()
	if not ready then return end

	for _, client in pairs(clients) do
		local data = client.socket:receive()
		if data then
			-- workaround for missing 'continue' statement in Lua
			while true do
				logmsg("Received: "..data)
				-- FIX: split on newline
				-- FIX: check length
				local cmd = JSON:decode(data)
				if #cmd == 0 then
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
				else
					logmsg(string.format("Unknown command '%d'", arg1))
				end
				break
			end
		end
	end
end

function LuaExportAfterNextFrame()
--function LuaExportActivityNextEvent(t)
	if not ready then return end

	local client_socket = server:accept()
	if client_socket then
		local client = new_client(client_socket)
		clients[client] = client
		logmsg("Client connected")
		client_socket:settimeout(0)
		client_socket:setoption("tcp-nodelay", true)
		send_to_client(client, "[0, \""..aircraft.."\"]\n")
	end
	for k, client in pairs(clients) do
		send_data(client)
	end
end

function string_split(s)
	local i = 1
	local list = {}
	s:gsub("[^%s]+", function(s) list[i] = s; i = i + 1 end)
	return list
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


-- cmd: [2, device, command, value ]
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

	GetDevice(device):performClickableAction(command, value)
end


-- client: 
-- cmd: [ 3, gauge_name, id, { f=value, p=value }] 
-- FIX: allow list of gauges as well, i.e:
--   [ 3, [gauge_name, id { f=value, p=value }], [ gauge_name ...] ]   
function handle_subscribe(client, cmd)
	-- get:
	-- * frequency
	-- * precission
	-- * own ID
	local opt_id
	local opt_freq = 10
	local opt_prec = 0

	if cmd[2] == nil then
		logmsg("No gauge argument found")
		return
	end
	local gauge_name = cmd[2]:lower()
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
	local options = cmd[4]
	if options then
		if options.f then
			opt_freq = tonumber(options.f)
		end
		if options.p then
			opt_prec = tonumber(options.p)
		end
		if opt_freq == 0 then
			client.subscribed_gauges[gauge.arg_number] = nil
			logmsg("Unsubscribing from "..gauge_name)
			return
		end
	end
	logmsg("Subscribing to "..gauge_name)
	client.subscribed_gauges[gauge.arg_number] = { 
		gauge = gauge,
		precission = opt_prec,
		id = opt_id,
		period = 1/opt_freq
	}
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
		subscribed_gauges = {}
	}
	return client
end