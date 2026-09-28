-- Neovim API stubs for Busted.

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

local function strchars(text)
	local _, count = text:gsub("[^\128-\191]", "")
	return count
end

_G.vim = {
	-- Sentinel used by the Neovim C layer for JSON null / GraphQL null values.
	NIL = {},
	o = { background = "dark" },

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

	-- Run scheduled callbacks immediately in tests.
	schedule = function(fn)
		fn()
	end,

	trim = function(value)
		return value:match("^%s*(.-)%s*$")
	end,

	fs = {
		basename = function(path)
			return path:match("[^/]*$")
		end,
		dirname = function(path)
			return path:match("^(.+)/[^/]*$") or (path:sub(1, 1) == "/" and "/" or ".")
		end,
	},

	filetype = {
		match = function()
			return nil
		end,
	},

	treesitter = {
		language = {
			get_lang = function(filetype)
				return filetype
			end,
		},
		get_string_parser = function()
			error("No Tree-sitter parsers in the test environment")
		end,
	},

	api = {
		nvim_create_namespace = function()
			return 1
		end,

		nvim_create_augroup = function()
			return 1
		end,

		nvim_create_autocmd = function()
			return 1
		end,

		nvim_set_hl = function() end,
		nvim_get_hl = function()
			return {}
		end,
	},

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

	list_extend = function(dst, src)
		for _, v in ipairs(src or {}) do
			table.insert(dst, v)
		end
		return dst
	end,

	tbl_keys = function(t)
		local keys = {}
		for k in pairs(t) do
			table.insert(keys, k)
		end
		return keys
	end,

	env = { HOME = os.getenv("HOME") or "" },

	json = { encode = json_encode },

	fn = {
		-- Layout fixtures use one-cell characters, including accented text and icons.
		strdisplaywidth = strchars,
		strchars = strchars,
		strcharpart = function(text, start, length)
			local chars = {}
			for char in text:gmatch("[^\128-\191][\128-\191]*") do
				chars[#chars + 1] = char
			end
			return table.concat(chars, "", start + 1, math.min(#chars, start + length))
		end,
		fnamemodify = function(path, _)
			return path
		end,
		stdpath = function(_)
			return "/tmp"
		end,
	},
}
