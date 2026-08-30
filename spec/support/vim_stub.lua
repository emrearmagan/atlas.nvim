-- Minimal stub for the `vim` global so specs can run outside Neovim via busted.
-- Loaded once as a busted helper (--helper=spec/support/vim_stub.lua).
-- Individual spec files no longer need their own `if vim == nil then` blocks.

if vim ~= nil then
	return
end

local function json_encode(value)
	local value_type = type(value)
	if value_type == "string" then
		return '"' .. value:gsub('[\\"]', "\\%0"):gsub("\n", "\\n") .. '"'
	elseif value_type == "number" or value_type == "boolean" then
		return tostring(value)
	elseif value_type == "table" then
		local keys = {}
		for key in pairs(value) do
			table.insert(keys, key)
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		local parts = {}
		for _, key in ipairs(keys) do
			table.insert(parts, string.format('"%s":%s', tostring(key), json_encode(value[key])))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "null"
end

_G.vim = {
	-- Sentinel used by the Neovim C layer for JSON null / GraphQL null values.
	NIL = {},

	-- vim.split(s, sep, {plain=true|false})
	split = function(s, sep, opts)
		local plain = opts and opts.plain
		local result = {}
		local from = 1
		while true do
			local start, finish = s:find(sep, from, plain)
			if not start then
				table.insert(result, s:sub(from))
				break
			end
			table.insert(result, s:sub(from, start - 1))
			from = finish + 1
		end
		return result
	end,

	-- vim.schedule(fn) -> run immediately; specs are single-threaded
	schedule = function(fn)
		fn()
	end,

	trim = function(value)
		return value:match("^%s*(.-)%s*$")
	end,

	api = {
		nvim_create_namespace = function()
			return 1
		end,
	},

	-- vim.tbl_extend(behavior, ...) -> shallow merge honoring "keep"/"force"/"error"
	tbl_extend = function(behavior, ...)
		assert(
			behavior == "keep" or behavior == "force" or behavior == "error",
			"vim.tbl_extend: unsupported behavior " .. tostring(behavior)
		)
		local out = {}
		for index = 1, select("#", ...) do
			for k, v in pairs(select(index, ...) or {}) do
				if out[k] == nil or behavior == "force" then
					out[k] = v
				elseif behavior == "error" then
					error("vim.tbl_extend: key found in more than one map: " .. tostring(k))
				end
			end
		end
		return out
	end,

	-- vim.list_extend(dst, src) -> append src onto dst in place
	list_extend = function(dst, src)
		for _, v in ipairs(src or {}) do
			table.insert(dst, v)
		end
		return dst
	end,

	-- vim.tbl_keys(t) -> list of the table's keys
	tbl_keys = function(t)
		local keys = {}
		for k in pairs(t) do
			table.insert(keys, k)
		end
		return keys
	end,

	env = { HOME = os.getenv("HOME") or "" },

	-- vim.json.encode(value) -> minimal JSON encoder for plain Lua values
	json = { encode = json_encode },

	fn = {
		fnamemodify = function(path, _)
			return path
		end,
		strdisplaywidth = function(value)
			return #value
		end,
		stdpath = function(_)
			return "/tmp"
		end,
	},
}
