local M = {}

local bit = require("bit")

local function sha1(value)
	local bytes = { value:byte(1, -1) }
	local bit_length = #bytes * 8
	bytes[#bytes + 1] = 128
	while #bytes % 64 ~= 56 do
		bytes[#bytes + 1] = 0
	end
	for shift = 7, 0, -1 do
		bytes[#bytes + 1] = math.floor(bit_length / 256 ^ shift) % 256
	end

	local h0, h1, h2, h3, h4 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0
	for offset = 1, #bytes, 64 do
		local words = {}
		for index = 0, 15 do
			local start = offset + index * 4
			words[index] = bit.bor(
				bit.lshift(bytes[start], 24),
				bit.lshift(bytes[start + 1], 16),
				bit.lshift(bytes[start + 2], 8),
				bytes[start + 3]
			)
		end
		for index = 16, 79 do
			words[index] =
				bit.rol(bit.bxor(words[index - 3], words[index - 8], words[index - 14], words[index - 16]), 1)
		end

		local a, b, c, d, e = h0, h1, h2, h3, h4
		for index = 0, 79 do
			local f, k
			if index < 20 then
				f, k = bit.bor(bit.band(b, c), bit.band(bit.bnot(b), d)), 0x5a827999
			elseif index < 40 then
				f, k = bit.bxor(b, c, d), 0x6ed9eba1
			elseif index < 60 then
				f, k = bit.bor(bit.band(b, c), bit.band(b, d), bit.band(c, d)), 0x8f1bbcdc
			else
				f, k = bit.bxor(b, c, d), 0xca62c1d6
			end
			local next_a = bit.tobit(bit.rol(a, 5) + f + e + k + words[index])
			e, d, c, b, a = d, c, bit.rol(b, 30), a, next_a
		end
		h0 = bit.tobit(h0 + a)
		h1 = bit.tobit(h1 + b)
		h2 = bit.tobit(h2 + c)
		h3 = bit.tobit(h3 + d)
		h4 = bit.tobit(h4 + e)
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
