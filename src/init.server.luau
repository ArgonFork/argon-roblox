--!strict
local RunService = game:GetService("RunService")

-- Detect play-mode transitions via Heartbeat (IsRunning is a method, not a property,
-- so GetPropertyChangedSignal can't be used).
local wasRunning = RunService:IsRunning()
RunService.Heartbeat:Connect(function()
	local isRunning = RunService:IsRunning()
	if isRunning == wasRunning then return end
	wasRunning = isRunning

	-- Restart StreamInput on every play-mode transition.
	-- start() is idempotent: it stops any existing loop then creates a fresh VirtualInput.
	print("[Argon] play mode " .. (isRunning and "started" or "ended") .. " — restarting StreamInput on 127.0.0.1:7286")
	local ok, StreamInput = pcall(require, script.Core.StreamInput)
	if ok then
		StreamInput.start("127.0.0.1", 7286)
	else
		warn("[Argon] Failed to require StreamInput:", tostring(StreamInput))
	end
end)

if RunService:IsRunning() then
	return
end

local Config = require(script.Config)
local Log = require(script.Log)
local App = require(script.App)

Config.load()
Log.__setLevel(Config:get("LogLevel"))
App.new()

print("[Argon] plugin loaded (edit mode)")

-- Start viewport input polling immediately in edit mode.
-- The Heartbeat above will restart it (with a fresh VirtualInput) on play-mode transitions.
local siOk, StreamInput = pcall(require, script.Core.StreamInput)
if siOk then
	StreamInput.start("127.0.0.1", 7286)
else
	warn("[Argon] Failed to require StreamInput:", tostring(StreamInput))
end

Config:onChanged("LogLevel", function(level)
	Log.__setLevel(level)
end)
