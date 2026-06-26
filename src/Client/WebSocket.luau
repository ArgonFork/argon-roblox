--!strict
-- WebSocket transport for the Argon client.
-- Same public interface as Client/init.luau's HTTP transport so Core/init.luau
-- needs no changes: subscribe/unsubscribe/fetchDetails/getSnapshot/read/write/open
-- all behave identically from the caller's perspective.
--
-- Wire format: base64(msgpack(frame)) as text frames.
-- Roblox WebSocketClient.Send only supports text frames; base64 wraps binary MsgPack.
-- If Studio gains binary frame support, remove Base64 calls and test the encoding flag.
--
-- Session protocol:
--   1. Connect (HttpService:WebSocket) — blocks until WS handshake done.
--   2. First frame → Subscribe {clientId, name}; server responds Ok.
--   3. Server pushes SyncChanges/SyncDetails/ExecuteCode/Disconnect on id=0.
--   4. Plugin sends requests on id>0; server echoes id in response frame.

local HttpService = game:GetService("HttpService")

local Argon = script:FindFirstAncestor("Argon Extended")

local Promise = require(Argon.Packages.Promise)
local MsgPack = require(Argon.Lib.MsgPack)
local Place = require(Argon.Place)
local Log = require(Argon.Log)
local Types = require(Argon.Types)

local Base64 = require(script.Parent.Base64)
local Error = require(script.Parent.Error)

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function encodeFrame(id: number, kind: string, data: any?): string
	local payload = { kind = kind }
	if data ~= nil then
		payload.data = data
	end
	return Base64.encode(MsgPack.encode({ id = id, payload = payload }))
end

local function decodeFrame(text: string): { id: number, payload: { kind: string, data: any? } }
	return MsgPack.decode(Base64.decode(text))
end

-- ── WebSocket transport ───────────────────────────────────────────────────────

local WebSocket = {}
WebSocket.__index = WebSocket

-- Check if Studio has the WebSocket API (added 2024).
-- See: https://devforum.roblox.com/t/websockets-support-in-studio-is-now-available/4021932
function WebSocket.isAvailable(): boolean
	local ok, result = pcall(function()
		return typeof((HttpService :: any).WebSocket)
	end)
	return ok and result == "function"
end

function WebSocket.new(host: string, port: number)
	local self = setmetatable({}, WebSocket)

	self.isSubscribed = false
	self.clientId = math.floor(math.random() * 10 ^ 9)
	self.placeName = Place.Name
	self.host = host
	self.port = port

	-- Internal state
	self._ws = nil :: any
	self._connected = false
	self._gracefulClose = false
	self._nextId = 1
	self._pending = {} :: { [number]: { resolve: (any) -> (), reject: (any) -> () } }
	self._pushQueue = {} :: { { kind: string, data: any? } }
	self._pushWaiters = {} :: { { resolve: (any) -> (), reject: (any) -> () } }

	return self
end

local MAX_RECONNECT_ATTEMPTS = 8

-- ── Internal: connect + handshake ────────────────────────────────────────────

-- Opens the WebSocket and sends the mandatory Subscribe frame.
-- Must succeed before any other request can be sent.
function WebSocket:_connectAndSubscribe(): Promise.Promise
	if self._connected then
		return Promise.resolve()
	end

	return Promise.new(function(resolve, reject)
		local url = string.format("ws://%s:%d/ws", self.host, self.port)
		local ok, ws = pcall(function()
			return (HttpService :: any):WebSocket(url)
		end)

		if not ok then
			return reject(Error.fromMessage(ws :: string))
		end

		self._ws = ws
		self._connected = true

		ws.OnMessage:Connect(function(text: string)
			self:_onMessage(text)
		end)

		ws.OnClose:Connect(function()
			self:_onClose()
		end)

		-- Subscribe is the server's required first frame; register the pending resolve
		local id = self._nextId
		self._nextId += 1
		self._pending[id] = { resolve = resolve, reject = reject }

		local frame = encodeFrame(id, "subscribe", {
			clientId = self.clientId,
			name = self.placeName,
		})
		ws:Send(frame)
	end)
end

-- ── Internal: frame routing ───────────────────────────────────────────────────

function WebSocket:_onMessage(text: string)
	local ok, frame = pcall(decodeFrame, text)
	if not ok then
		Log.warn("WS decode error:", frame)
		return
	end

	local id: number = frame.id
	local payload = frame.payload

	if id == 0 then
		-- Server-push frame: route to the next read() waiter or buffer it
		local waiter = table.remove(self._pushWaiters, 1)
		if waiter then
			waiter.resolve(payload)
		else
			table.insert(self._pushQueue, payload)
		end
	else
		-- Response to a plugin request
		local pending = self._pending[id]
		if not pending then
			return
		end
		self._pending[id] = nil

		if payload.kind == "err" then
			local msg = (payload.data and payload.data.message) or "WS server error"
			pending.reject(Error.fromMessage(msg))
		else
			pending.resolve(payload)
		end
	end
end

function WebSocket:_onClose()
	self._connected = false

	-- Reject all in-flight requests regardless of close reason
	local err = Error.new(Error.ConnectionClosed)
	for id, pending in self._pending do
		pending.reject(err)
		self._pending[id] = nil
	end

	if self._gracefulClose then
		-- Deliberate close (unsubscribe called): signal read() waiters to stop
		self.isSubscribed = false
		for _, waiter in self._pushWaiters do
			waiter.reject(err)
		end
		self._pushWaiters = {}
		return
	end

	-- Unexpected drop: keep push waiters alive and attempt transparent reconnect.
	-- read() callers stay suspended; they resume once the new connection is up.
	Log.warn("WS connection lost, reconnecting...")
	task.spawn(function()
		self:_reconnect(0)
	end)
end

function WebSocket:_reconnect(attempt: number)
	if self._gracefulClose then
		return
	end

	if attempt >= MAX_RECONNECT_ATTEMPTS then
		Log.warn("WS: max reconnect attempts reached")
		local err = Error.new(Error.ConnectionClosed)
		for _, waiter in self._pushWaiters do
			waiter.reject(err)
		end
		self._pushWaiters = {}
		self.isSubscribed = false
		return
	end

	-- Exponential backoff capped at 30s: 1,2,4,8,16,30,30,...
	local delay = math.min(2 ^ attempt, 30)
	Log.debug(string.format("WS reconnect attempt %d/%d in %.0fs", attempt + 1, MAX_RECONNECT_ATTEMPTS, delay))
	task.wait(delay)

	if self._gracefulClose then
		return
	end

	-- Reset connection state; _connectAndSubscribe sees _connected=false and proceeds
	self._nextId = 1

	local ok, reconnErr = pcall(function()
		self:_connectAndSubscribe():expect()
	end)

	if ok then
		self.isSubscribed = true
		Log.debug("WS reconnected successfully")
		-- Push waiters are still in _pushWaiters; they will resolve on next push
	else
		Log.warn("WS reconnect failed:", tostring(reconnErr))
		self:_reconnect(attempt + 1)
	end
end

-- ── Internal: request/response ────────────────────────────────────────────────

function WebSocket:_request(kind: string, data: any?): Promise.Promise
	return Promise.new(function(resolve, reject)
		if not self._connected then
			return reject(Error.fromMessage("WebSocket not connected"))
		end

		local id = self._nextId
		self._nextId += 1
		self._pending[id] = { resolve = resolve, reject = reject }

		local ok, err = pcall(function()
			self._ws:Send(encodeFrame(id, kind, data))
		end)
		if not ok then
			self._pending[id] = nil
			reject(Error.fromMessage(err :: string))
		end
	end)
end

-- Returns the next server-push frame (blocks if none queued).
function WebSocket:_receivePush(): Promise.Promise
	if #self._pushQueue > 0 then
		return Promise.resolve(table.remove(self._pushQueue, 1))
	end
	return Promise.new(function(resolve, reject)
		table.insert(self._pushWaiters, { resolve = resolve, reject = reject })
	end)
end

-- ── Public interface (mirrors Client/init.luau HTTP transport) ────────────────

function WebSocket:fetchDetails(): Promise.TypedPromise<Types.Project>
	Log.trace("WS request: details")

	return self:_connectAndSubscribe():andThen(function()
		return self:_request("details")
	end):andThen(function(resp)
		return resp.data
	end)
end

function WebSocket:subscribe(): Promise.Promise
	Log.trace("WS subscribe")

	-- Connection + WS-level Subscribe already happen in fetchDetails/_connectAndSubscribe.
	-- This call finalises isSubscribed to match the HTTP transport's state flag.
	return self:_connectAndSubscribe():andThen(function()
		self.isSubscribed = true
	end)
end

function WebSocket:unsubscribe(): Promise.Promise
	Log.trace("WS request: unsubscribe")

	return self:_request("unsubscribe"):andThen(function()
		self._gracefulClose = true -- prevent reconnect on the WS close that follows
		self.isSubscribed = false
		pcall(function()
			self._ws:Close()
		end)
	end):catch(function(err)
		if err == Error.ConnectionClosed then
			self._gracefulClose = true
			self.isSubscribed = false
		else
			return Promise.reject(err)
		end
	end)
end

function WebSocket:getSnapshot(instance: Types.Ref?): Promise.TypedPromise<Types.AddedSnapshot>
	Log.trace("WS request: snapshot")

	return self:_request("snapshot", {
		instance = instance or buffer.create(16),
	}):andThen(function(resp)
		return resp.data
	end)
end

-- Returns the next server-push message in the same format as the HTTP read()
-- result so Core/init.luau's __startSyncLoop dispatch works unchanged:
--   {SyncChanges = <changes>}, {ExecuteCode = {code}}, etc.
function WebSocket:read(): Promise.TypedPromise<Types.Message>
	return self:_receivePush():andThen(function(payload)
		local kind: string = payload.kind

		-- Server ack for client writes; Core doesn't handle this, skip it
		if kind == "syncbackChanges" then
			return self:read()
		end

		-- Convert camelCase → PascalCase to match the HTTP transport's msgpack enum tag
		local messageKind = kind:sub(1, 1):upper() .. kind:sub(2)
		return { [messageKind] = payload.data }
	end)
end

function WebSocket:write(changes: Types.Changes): Promise.Promise
	Log.trace("WS request: write")

	return self:_request("write", {
		clientId = self.clientId,
		changes = changes,
	})
end

function WebSocket:open(instance: Types.Ref, line: number): Promise.Promise
	Log.trace("WS request: open")

	return self:_request("open", {
		instance = instance,
		line = line,
	})
end

return WebSocket
