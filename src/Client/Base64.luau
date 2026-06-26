--!strict
-- Base64 encode/decode for binary strings (Luau strings are byte arrays).
-- Used by the WebSocket transport to wrap MsgPack frames in text frames.

local CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local lookup: { [string]: number } = {}
for i = 1, #CHARS do
	lookup[CHARS:sub(i, i)] = i - 1
end

local Base64 = {}

function Base64.encode(data: string): string
	local out = {}
	local n = #data

	for i = 1, n, 3 do
		local b0 = data:byte(i)
		local b1 = data:byte(i + 1) or 0
		local b2 = data:byte(i + 2) or 0

		local v = bit32.lshift(b0, 16) + bit32.lshift(b1, 8) + b2
		local c0 = bit32.rshift(v, 18) % 64 + 1
		local c1 = bit32.rshift(v, 12) % 64 + 1
		local c2 = bit32.rshift(v, 6) % 64 + 1
		local c3 = v % 64 + 1

		out[#out + 1] = CHARS:sub(c0, c0)
		out[#out + 1] = CHARS:sub(c1, c1)
		out[#out + 1] = i + 1 <= n and CHARS:sub(c2, c2) or "="
		out[#out + 1] = i + 2 <= n and CHARS:sub(c3, c3) or "="
	end

	return table.concat(out)
end

function Base64.decode(b64: string): string
	local out = {}
	local n = #b64

	for i = 1, n, 4 do
		local c0 = lookup[b64:sub(i, i)] or 0
		local c1 = lookup[b64:sub(i + 1, i + 1)] or 0
		local c2 = lookup[b64:sub(i + 2, i + 2)]
		local c3 = lookup[b64:sub(i + 3, i + 3)]

		local v = bit32.lshift(c0, 18) + bit32.lshift(c1, 12)
		out[#out + 1] = string.char(bit32.rshift(v, 16) % 256)

		if c2 then
			v += bit32.lshift(c2, 6)
			out[#out + 1] = string.char(bit32.rshift(v, 8) % 256)
		end

		if c3 then
			out[#out + 1] = string.char((v + c3) % 256)
		end
	end

	return table.concat(out)
end

return Base64
