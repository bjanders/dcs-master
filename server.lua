-- Copyright (c) Björn Andersson

package.path  = package.path..";.\\LuaSocket\\?.lua"
package.cpath = package.cpath..";.\\LuaSocket\\?.dll"
  
local socket = require("socket")
local server
local client
local logf 

local gauges
local gauge_defs
local clickables
local JSON
local seen={}
local ready = false
local clients = {}

local CLASS_NULL = 0
local CLASS_BTN = 1
local CLASS_TUMB = 2
local CLASS_SNGBTN = 3
local CLASS_LEV = 4
local CLASS_MOVABLE_LEV = 5

local CMD_BTN = 1
local CMD_CMD = 2
local CMD_SUB = 3

local BTN_UP = 0
local BTN_DOWN = 1
local BTN_SET = 2

function LuaExportStart()
	logf = io.open(lfs.writedir().."/Logs/dcs-master.log", "w")
	logmsg("DCS Master started")
	local self = LoGetSelfData()
	if not self then
		logmsg("No SelfData, exiting")
		return
	end
	logmsg("Current aircraft is "..self.Name)

	--logmsg(lfs.currentdir())
	server = socket.bind("*", 8888)
	server:settimeout(0)
	gauges = GetDevice(0)
	JSON = loadfile("Scripts/JSON.lua")()
	if read_cockpit(self.Name) then
		logmsg("Succesfully loaded cockpit info")
		ready = true
	else
		logmsg("Failed to load cockpit info")
	end
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
			logmsg("Received: "..data)
			-- FIX: split on newline
			-- FIX: check length
			local cmd = JSON:decode(data)
			if #cmd == 0 then
				logmsg("Data contains no command")
				return
			end
			local arg1 = cmd[1]
			if type(arg1) ~= "number" then
				logmsg("Command must be number")
				return
			end
			if arg1 == CMD_BTN then
				handle_button(client, cmd)
				return
			end
			if arg1 == CMD_SUB then
				handle_subscribe(client, cmd)
				return
			end
			logmsg(string.format("Unknown command '%s'", arg1))
			return
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
	end

	for k, client in pairs(clients) do
		send_data(client)
	end
--	return t + 0.1
end

function dump(t, i)
    seen[t]=true
    local s={}
	local n=0
	for k in pairs(t) do
		n=n+1 s[n]=k
	end
	table.sort(s)
	for k,v in ipairs(s) do
		-- print(v)
		logf:write(string.format("%s\t%s\n", i, v))
		v=t[v]
		if type(v)=="table" and not seen[v] then
			dump(v, i.."\t")
		end
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

function interpolate(x, xx, yy)
	-- FIX: handle reverse order
	if x == nil then return nil end

	local i

	if #xx == 2 then
		i = 2
	else
		for j, v in ipairs(xx) do
			if x <= v then
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
		error(err)
	end
	local json_str = jfile:read("*a")
	jfile:close()
	return JSON:decode(json_str)
end

function load_gauges(aircraft)
	local temp_gauges = read_json(lfs.writedir().."/Scripts/dcs-master/aircraft/"..aircraft.."/gauges.json")
	if not temp_gauges then
		logmsg("Failed to read gauges")
		return false
	end
	gauge_defs = {}
	for k, v in pairs(temp_gauges) do
		v.name = k
		gauge_defs[k:lower()] = v
		if v.arg_number then
			gauge_defs[v.arg_number] = v
		end
	end
	return true
end


function load_clickables(aircraft)
	local temp_clickables = read_json(lfs.writedir().."/Scripts/dcs-master/aircraft/"..aircraft.."/clickables.json")
	if not temp_clickables then
		logmsg("Failed to read clickables")
		return false
	end
	clickables = {}
	for k, v in pairs(temp_clickables) do
		clickables[k:lower()] = v
	end
	return true
end

function read_cockpit(aircraft)
	if not load_clickables(aircraft) then
		return
	end
	return load_gauges(aircraft) 
end

-- action: BTN_UP, BTN_DOWN, BTN_SET
-- clickable: Name of clickable
-- value: Must be set if action == BTN_SET
function scroll_clickable(action, clickable, value)

	local i = clickables[clickable]
	if i == nil then
		logmsg("Did not find clickable for "..clickable)
		return
	end
	logmsg("Found clickable for "..clickable)

	local pos = 0
	for n, class in ipairs(i.class) do
		if class == CLASS_LEV then
			pos = n
		end
	end
	if pos == 0 then
		logmsg("No lever found")
		return
	end
end

-- pos: 1 (left click) or 2 (right click)
-- action: BTN_UP, BTN_DOWN, BTN_SET
-- clickable: Name of clickable
-- value: Must be set if action == BTN_SET
function click_clickable(pos, action, clickable, value)

	if pos < 1 or pos > 2 then
		logmsg("Only button 1 or 2 allowed, "..pos.." given")
		return
	end
	local i = clickables[clickable]
	if i == nil then
		logmsg("Did not find clickable for "..clickable)
		return
	end
	logmsg("Found clickable for "..clickable)

	if i.class[pos] ~= CLASS_BTN and i.class[pos] ~= CLASS_TUMB then
		logmsg("No button found in pos "..pos)
		return
	end
	
	-- Set value directly
	if action == BTN_SET then
		if not value then
			logmsg("Attempting direct set of clickable without a value")
			return
		end
		if value < i.arg_lim[pos][1] or value > i.arg_lim[pos][2] then
			logmsg("Attempting to set value out of limits")
			return
		end
		logmsg("Setting button to "..value)
		GetDevice(i.device):performClickableAction(i.action[pos], value)
		return
	end

	-- BTN down
	if i.class[pos] == CLASS_BTN and action == BTN_DOWN then
		logmsg("Setting button to "..i.arg_value[pos])
		GetDevice(i.device):performClickableAction(i.action[pos], i.arg_value[pos])
		return
	end

	-- BTN up
	if action == BTN_UP then
		if i.class[pos] == CLASS_TUMB then
			logmsg("Button up has no effect on tumbs")
			return
		end
		if i.stop_action[pos] == nil then
			logmsg("No stop_action found for button")
			return
		end
		GetDevice(i.device):performClickableAction(i.stop_action[pos], 0)
		return
	end
		
	-- TUMB down
	logmsg(string.format("device: %d, action: %d, arg_value: %d", i.device, i.action[pos], i.arg_value[pos]))
	local v = gauges:get_argument_value(i.arg[pos])
	logmsg("current: "..v)
	local newval = v + i.arg_value[pos]
	if i.cycle == false and (newval < i.arg_lim[pos][1] or newval > i.arg_lim[pos][2]) then
		logmsg("New val outside limits")
		return
	end
	if newval < i.arg_lim[pos][1] then
		logmsg("Cycling value")
		newval = i.arg_lim[pos][2]
	elseif newval > i.arg_lim[pos][2] then
		logmsg("Cycling value")
		newval = i.arg_lim[pos][1]
	end
	
	logmsg("Setting new value "..newval)
	GetDevice(i.device):performClickableAction(i.action[pos], newval)
	logmsg("Done")
end

function string_strip(s)
	local m = s:find("%s")
	if m then
		return s:sub(m)
	end
	return s
end

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
		return
	end
	if gauge.arg_number == nil then
		logmsg("No arg_number for arg "..gauge_name)
		return
	end
	local options = cmd[3]
	local opt_id = gauge.arg_number
	if options then
		if options.freq then
			opt_freq = tonumber(options.freq)
		end
		if options.prec then
			opt_prec = tonumber(options.prec)
		end
		if options.id then
			opt_id = options.id
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

function handle_button(client, cmd)
	if #cmd < 4 then
		logmsg("Not enough arguments to handle clickable")
		return
	end
	local pos = cmd[2]
	local action = cmd[3]
	local clickable = cmd[4]:lower()
	if type(pos) ~= "number" then
		logmsg("Button number must be a number")
		return
	end
	if type(action) ~= "number" then
		logmsg("Action must be a number")
		return
	end
	local value
	if #cmd > 4 then
		value = cmd[5]
		if type(value) ~= "number" then
			logmsg("Clickable value must be a number")
			return
		end
	end
	logmsg(string.format("pos: %d, action: %d, clickable: %s",
		pos, action, clickable))
	click_clickable(pos, action, clickable, value)
end



function round(x, e)
	if x == nil then return nil end
	local d = math.pow(10, e)
	return math.floor(x * d) / d
end

function send_json(client, gauges)
	local s = "[1"
	for _, gauge in pairs(gauges) do
		local fmt = ", [%s, %."..gauge.precission.."f]"
		s = s..fmt:format(gauge.id, gauge.gauge_value)
	end
	s = s.."]\n"
	send_to_client(client, s)
end

function send_data(client)
	local send_gauges = {}
	local t = LoGetModelTime()
	for arg_number, gauge in pairs(client.subscribed_gauges) do
		if gauge.send_time and gauge.send_time + gauge.period >= t then
			break
		end
		local output = gauges:get_argument_value(arg_number)
		input = round(interpolate(output, gauge.gauge.output, gauge.gauge.input), gauge.precission)
		if gauge.gauge_value == input then
			break
		end
		gauge.gauge_value = input
		gauge.send_time = t
		send_gauges[#send_gauges+1] = gauge
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
