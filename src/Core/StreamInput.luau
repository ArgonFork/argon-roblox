-- Polls /plugin_input to track viewport stream daemon connection status.
-- Actual keyboard/mouse injection is done at the OS level (X11 send_event)
-- by argon-ex stream, so no input handling is needed here.
--
-- StreamInput.start(host, port)
-- StreamInput.stop()

local HttpService = game:GetService("HttpService")

local StreamInput = {}
local running = false

function StreamInput.start(host, port)
	if running then StreamInput.stop() end
	running = true

	local url = ("http://%s:%d/plugin_input"):format(host, port)
	print("[Argon] StreamInput watching", url)

	task.spawn(function()
		local connected = false
		while running do
			local ok, result = pcall(function()
				return HttpService:RequestAsync({ Url = url, Method = "GET" })
			end)
			if not running then break end
			if ok and result.StatusCode == 200 then
				if not connected then
					connected = true
					print("[Argon] Viewport stream daemon connected — inputs injected via X11")
				end
			else
				if connected then
					connected = false
					print("[Argon] Viewport stream daemon disconnected")
				end
				task.wait(1)
			end
		end
	end)
end

function StreamInput.stop()
	running = false
end

return StreamInput
