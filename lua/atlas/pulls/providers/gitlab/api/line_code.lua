local M = {}

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, rol, tobit = bit.lshift, bit.rshift, bit.rol, bit.tobit

-- Copied from: https://github.com/charlesnicholson/plantuml.nvim/blob/main/lua/plantuml/sha1.lua
local function big_endian(value)
	return string.char(
		band(rshift(value, 24), 255),
		band(rshift(value, 16), 255),
		band(rshift(value, 8), 255),
		band(value, 255)
	)
end

local function sha1(value)
	local h0, h1, h2, h3, h4 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0
	local length = #value
	value = value .. "\128" .. string.rep("\0", (55 - length) % 64) .. big_endian(0) .. big_endian(length * 8)
	for offset = 1, #value, 64 do
		local words = {}
		for index = 0, 15 do
			local start = offset + index * 4
			words[index] = bor(
				lshift(value:byte(start), 24),
				lshift(value:byte(start + 1), 16),
				lshift(value:byte(start + 2), 8),
				value:byte(start + 3)
			)
		end
		for index = 16, 79 do
			words[index] = rol(bxor(words[index - 3], words[index - 8], words[index - 14], words[index - 16]), 1)
		end

		local a, b, c, d, e = h0, h1, h2, h3, h4
		for index = 0, 79 do
			local f, k
			if index < 20 then
				f, k = bor(band(b, c), band(bnot(b), d)), 0x5a827999
			elseif index < 40 then
				f, k = bxor(b, c, d), 0x6ed9eba1
			elseif index < 60 then
				f, k = bor(band(b, c), band(b, d), band(c, d)), 0x8f1bbcdc
			else
				f, k = bxor(b, c, d), 0xca62c1d6
			end
			local next_a = tobit(rol(a, 5) + f + e + k + words[index])
			e, d, c, b, a = d, c, rol(b, 30), a, next_a
		end
		h0, h1, h2, h3, h4 = tobit(h0 + a), tobit(h1 + b), tobit(h2 + c), tobit(h3 + d), tobit(h4 + e)
	end

	return bit.tohex(h0) .. bit.tohex(h1) .. bit.tohex(h2) .. bit.tohex(h3) .. bit.tohex(h4)
end

---@param path string
---@param old_line integer|nil
---@param new_line integer|nil
---@return string
function M.encode(path, old_line, new_line)
	return string.format("%s_%d_%d", sha1(path), old_line or 0, new_line or 0)
end

return M
