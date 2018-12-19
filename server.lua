package.path  = package.path..";.\\LuaSocket\\?.lua"
package.cpath = package.cpath..";.\\LuaSocket\\?.dll"
  
local socket = require("socket")
local server
local client
local logf 

local gauges
local gauge_values = {}
local gauge_defs
local clickables
local JSON
local seen={}
local subscribed_gauges = {}
local ready = false

local CLASS_NULL = 0
local CLASS_BTN = 1
local CLASS_TUMB = 2
local CLASS_SNGBTN = 3
local CLASS_LEV = 4
local CLASS_MOVABLE_LEV = 5

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
	string.gsub(s, "[^%s]+", function(s) list[i] = s; i = i + 1 end)
	return list
end

function logmsg(msg)
	logf:write(msg.."\r\n")
end

function interpolate(x, xx, yy)
	-- FIX: handle reverse order
	if x == nil then return nil end
	local i
	for j, v in ipairs(xx) do
		if x <= v then
			i = j
			break
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
	if temp_gauges == nil then
		logmsg("Failed to read gauges")
		return false
	end
	gauge_defs = {}
	for k, v in pairs(temp_gauges) do
--		logmsg(k)
		v.name = k
		gauge_defs[string.lower(k)] = v
		if v.arg_number then
			gauge_defs[v.arg_number] = v
		end
	end
	return true
end

function read_cockpit(aircraft)
	clickables = read_json(lfs.writedir().."/Scripts/dcs-master/aircraft/"..aircraft.."/clickables.json")
	if clickables == nil then
		logmsg("Failed to read clickables")
		return false
	end
	return load_gauges(aircraft) 
end


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
	if client then
		client:close()
		client = nil
	end
	logmsg("DCS Master stopped")
end


function click_clickable(pos, action, clickable)

	if pos ~= 1 and pos ~= 2 then
		logmsg("Only butten 1 or 2 allowed, "..pos.." given")
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
	
	-- BTN down
	if i.class[pos] == CLASS_BTN and action == 'D' then
		logmsg("Setting button to "..i.arg_value[pos])
		GetDevice(i.device):performClickableAction(i.action[pos], i.arg_value[pos])
		return
	end

	-- BTN up
	if action == 'U' then
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
	local m = string.find(s, "%s")
	if m then
		return string.sub(s, m)
	end
	return s
end

function handle_subscribe(data)
	-- get:
	-- * frequency
	-- * precission
	-- * own ID
	local ownid
	local frequency = 10
	local cmd = string_split(data)
	if cmd[2] == nil then
		logmsg("No argument found")
		return
	end
	local gauge_name = string.lower(cmd[2])
	local precission = tonumber(cmd[3])
	local gauge = gauge_defs[gauge_name]
	if gauge == nil then
		logmsg("Found no gauge named "..gauge_name)
		return
	end
	if gauge.arg_number == nil then
		logmsg("No arg_number for arg "..gauge_name)
		return
	end
	if ownid == nil then
		ownid = gauge.arg_number
	end
	if precission == nil then
		precission = 0
	end
	if frequency == 0 then
		subscribed_gauges[gauge.arg_number] = nil
		logmsg("Unsubscribing from "..gauge_name)
		return
	end
	logmsg("Subscribing to "..gauge_name)
	subscribed_gauges[gauge.arg_number] = { 
		gauge = gauge,
		precission = precission,
		id = ownid,
		period = 1/frequency
	}
end

function handle_button(data)
	local pos = string.sub(data, 2, 2)
	local action = string.sub(data, 3, 3)
	local clickable = string.sub(data, 5)
	logmsg(string.format("class: %s, pos: %s, action: %s, clickable: %s",
		class, pos, action, clickable))
	pos = tonumber(pos)
	if pos == nil then
		logmsg(pos.." is not a number")
		return
	end
	click_clickable(pos, action, clickable)
end

function LuaExportBeforeNextFrame()
	if not ready then
		return
	end
	if client then
		local data = client:receive()
		if data then
			logmsg("Received: "..data)
			-- FIX: split on newline
			-- FIX: check length
			local cmd = string.lower(string.sub(data, 1, 1))
			if cmd == 'b' then
				handle_button(data)
				return
			end
			if cmd == 's' then
				handle_subscribe(data)
				return
			end
			logmsg(string.format("Unknown command '%s', cmd"))
			return
			--reply = assert(loadstring("return "..data))()
			--local s = string.format("%s\n", reply)
			--send_to_client(s)
			--GetDevice(31):performClickableAction(3008, 0.025)
			--GetDevice(31):SetCommand(3008, 0.025)
--			gauges:set_argument_value(191, 0.0)
--			gauges:update_arguments()
		end
	end
end


function round(x, e)
	if x == nil then return nil end
	local d = math.pow(10, e)
	return math.floor(x * d) / d
end

function send_json(send_values, e)
	local s = "[1"
	for gauge, input in pairs(send_values) do
		local fmt = ", [%s, %."..input[2].."f]"
		s = s..string.format(fmt, gauge, input[1])
	end
	s = s.."]\n"
	send_to_client(s)
end

function send_data()
	local send_values = {}
	local has_data = false
	for arg_number, info in pairs(subscribed_gauges) do
		local output = gauges:get_argument_value(arg_number)
		input = round(interpolate(output, info.gauge.output, info.gauge.input), info.precission)
		--local s = string.format("%s = %.3f", gauge, output)
		--logmsg(s)	
		if gauge_values[arg_number] == input then
			break
		end
		gauge_values[arg_number] = input
		send_values[info.id] = { input, info.precission }
		has_data = true
--		local s = string.format("%s = %.3f -> %.3f\n", gauge, output, input)
	end
	if has_data then
		-- FIX: optional CBOR
		send_json(send_values)
	end
end

function send_to_client(s)
	if not client then
		return
	end

	local res, errmsg, lastbyte = client:send(s)
	if res == nil then
		logmsg("Client error: "..errmsg)
		client = nil
	end

end	

--function LuaExportAfterNextFrame()
function LuaExportActivityNextEvent(t)
	if not ready then
		return
	end
	if client == nil and server then
		client = server:accept()
		if client then
			logmsg("Client connected")
			client:settimeout(0)
			client:setoption("tcp-nodelay", true)
		end
	end
	send_data()
	return t + 0.1
end