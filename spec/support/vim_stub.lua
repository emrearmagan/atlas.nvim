-- Minimal stub for the `vim` global so specs can run outside Neovim via busted.
-- Loaded once as a busted helper (--helper=spec/support/vim_stub.lua).
-- Individual spec files no longer need their own `if _G.vim == nil then` blocks.

if _G.vim ~= nil then
	return
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

	-- vim.inspect / vim.fn stubs used by various modules
	inspect = function(v)
		return tostring(v)
	end,

	-- vim.schedule(fn) -> run immediately; specs are single-threaded
	schedule = function(fn)
		fn()
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
				if out[k] == nil then
					out[k] = v
				elseif behavior == "force" then
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
	json = {
		encode = function(value)
			local t = type(value)
			if t == "string" then
				return '"' .. value:gsub('[\\"]', "\\%0"):gsub("\n", "\\n") .. '"'
			elseif t == "number" or t == "boolean" then
				return tostring(value)
			elseif t == "table" then
				local keys = {}
				for k in pairs(value) do
					table.insert(keys, k)
				end
				table.sort(keys, function(a, b)
					return tostring(a) < tostring(b)
				end)
				local parts = {}
				for _, k in ipairs(keys) do
					table.insert(parts, string.format('"%s":%s', tostring(k), _G.vim.json.encode(value[k])))
				end
				return "{" .. table.concat(parts, ",") .. "}"
			end
			return "null"
		end,
	},

	fn = {
		expand = function(x)
			if x == "~" then
				return os.getenv("HOME") or ""
			end
			return x
		end,
		fnamemodify = function(path, _)
			return path
		end,
		isdirectory = function(_)
			return 1
		end,
		stdpath = function(_)
			return "/tmp"
		end,
		writefile = function(_, _, _)
			return 0
		end,
	},
}
