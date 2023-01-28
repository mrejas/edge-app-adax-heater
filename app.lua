--
--
local tls = require("http.tls")
local edge = require("edge")
local openssl = require("openssl.ssl.context")
last_processed_date = nil

function findFunctionMeta(meta)
        functions, err = lynx.apiCall("GET", "/api/v2/functionx/" .. app.installation_id)
        local match = 1
        for i, dev in ipairs(functions) do
                match = 1;
                for k, v in pairs(meta) do
                        if dev.meta[k] ~= v then
                                match = 0
                        end
                end
                if match == 1 then
                        return functions[i]
                end
        end
        return nil;
end

function findDeviceMeta(meta)
        devices, err = lynx.apiCall("GET", "/api/v2/devicex/" .. app.installation_id)
        local match = 1
        for i, dev in ipairs(devices) do
                match = 1;
                for k, v in pairs(meta) do
                        if dev.meta[k] ~= v then
                                match = 0
                        end
                end
                if match == 1 then
                        return devices[i]
                end
        end
        return nil;
end

function createFunctionsIfNeeded(device)
	print("Creating thermostat")
	local func = findFunctionMeta({
		device_id = tostring(device),
		adax_type = "thermostat"
	})

	if func == nil then
		fn = {
			type = "thermostat",
			installation_id = app.installation_id,
			meta = {
				name = "Heater - Setpoint",
				adax_type = "thermostat",
				device_id = tostring(device),
				format = "%0.1f C",
				topic_read = "obj/adax/" .. cfg.ip_address .. "/target",
				topic_write = "set/adax/" .. cfg.ip_address .. "/target" 
			}
		}
		lynx.createFunction(fn)
	end

	print("Creating thermometer")
	local func = findFunctionMeta({
		device_id = tostring(device),
		adax_type = "temperature"
	})

	if func == nil then
		fn = {
			type = "temperature",
			installation_id = app.installation_id,
			meta = {
				name = "Heater - Temperature",
				adax_type = "temperature",
				device_id = tostring(device),
				format = "%0.1f C",
				topic_read = "obj/adax/" .. cfg.ip_address .. "/temperature" 
			}
		}
	lynx.createFunction(fn)
	end
end

function createDeviceIfNeeded() 
	local dev = findDeviceMeta({
		device_type = "heater",
		ip_address = cfg.ip_address
	})

	if dev == nil then
		print("Creating device")
		local _dev = {
			type = "heater",
			installation_id = app.installation_id,
			meta = {
				name = "Heater - " .. cfg.name,
				device_type = "heater",
				ip_address = cfg.ip_address
			}
		}
		
		lynx.apiCall("POST", "/api/v2/devicex/" .. app.installation_id , _dev)

		dev = findDeviceMeta({
			device_type = "heater",
			ip_address = cfg.ip_address
		})
	end
	return dev
end

function setTarget(topic, payload) 
	local p = json:decode(payload)
	local temperature = p["value"]

	local ctx = tls.new_client_context()
	local http_request = require "http.request"
	local url = "https://" .. cfg.ip_address .. "/api?command=set_target&value=" .. temperature * 100 .. "&time="  .. os.time()
	local request = http_request.new_from_uri(url)
	ctx:setVerify(openssl.VERIFY_NONE)
	request.ctx=ctx
	request.headers:upsert('Authorization', 'Basic ' .. cfg.token)
	local headers, stream = assert(request:go())
	local body = assert(stream:get_body_as_string())
	if headers:get ":status" ~= "200" then
	    -- error(body)
	    print("Could not fetch " .. url)
	    return nil
	end

	pollStatus()
end


function pollStatus()
	print("About to poll status")
	local ctx = tls.new_client_context()
	local http_request = require "http.request"
	local url = "https://" .. cfg.ip_address .. "/api?command=stat&time="  .. os.time()
	local request = http_request.new_from_uri(url)
	ctx:setVerify(openssl.VERIFY_NONE)
	request.ctx=ctx
	request.headers:upsert('Authorization', 'Basic ' .. cfg.token)
	local headers, stream = assert(request:go())
	local body = assert(stream:get_body_as_string())
	if headers:get ":status" ~= "200" then
	    error(body)
	    print("Could not fetch " .. url)
	    return nil
	end

	local data, err = json:decode(body)
	
	local newMessage = {value = data.currTemp/100, timestamp = os.time()}
	mq:pub("obj/adax/" .. cfg.ip_address .. "/temperature", json:encode(newMessage))

	newMessage = {value = data.targTemp/100, timestamp = os.time()}
        mq:pub("obj/adax/" .. cfg.ip_address .. "/target", json:encode(newMessage))
end

function onStart()
	print("Starting")

	local dev = createDeviceIfNeeded()

	print("Got device: " .. dev.id)

	createFunctionsIfNeeded(dev.id)


	pollStatus()
	local t = timer:interval(cfg.interval * 60, pollStatus)

	local setTopic = "set/adax/" .. cfg.ip_address .. "/target"
	mq:sub(setTopic, 0)
	mq:bind(setTopic, setTarget)
end
