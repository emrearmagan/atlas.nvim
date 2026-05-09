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

	env = { HOME = os.getenv("HOME") or "" },

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
