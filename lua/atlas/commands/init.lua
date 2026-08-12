local M = {}

local notify = require("atlas.core.notify")

---@class AtlasCommand
---@field name string
---@field description string
---@field run fun(args: string[])
---@field complete (fun(arglead: string): string[])|nil

---@type AtlasCommand[]
M.commands = {}

---@param command AtlasCommand
function M.register(command)
	command.name = command.name:lower()
	for index, current in ipairs(M.commands) do
		if current.name == command.name then
			M.commands[index] = command
			return
		end
	end
	table.insert(M.commands, command)
end

---@param name string
---@return AtlasCommand|nil
local function find_command(name)
	for _, command in ipairs(M.commands) do
		if command.name == name then
			return command
		end
	end
end

---@param domain "pulls"|"issues"
---@param arglead string
---@return string[]
local function complete_providers(domain, arglead)
	return vim.tbl_filter(function(provider)
		return provider:find(arglead, 1, true) == 1
	end, require("atlas.providers").ids(domain))
end

---@param args string[]
---@param prompt string
---@param callback fun(value: string)
local function with_argument(args, prompt, callback)
	local value = vim.trim(table.concat(args, " "))
	if value ~= "" then
		callback(value)
		return
	end

	vim.ui.input({ prompt = prompt }, function(input)
		if input and vim.trim(input) ~= "" then
			callback(vim.trim(input))
		end
	end)
end

M.register({
	name = "pulls",
	description = "Open pull requests",
	complete = function(arglead)
		return complete_providers("pulls", arglead)
	end,
	run = function(args)
		require("atlas").open("pulls", args[1] and args[1]:lower() or nil)
	end,
})

M.register({
	name = "issues",
	description = "Open issues",
	complete = function(arglead)
		return complete_providers("issues", arglead)
	end,
	run = function(args)
		require("atlas").open("issues", args[1] and args[1]:lower() or nil)
	end,
})

M.register({
	name = "search",
	description = "Search across providers",
	complete = function(arglead)
		return require("atlas.commands.search").complete(arglead)
	end,
	run = function(args)
		require("atlas.commands.search").run(args[1] and args[1]:lower() or nil)
	end,
})

M.register({
	name = "open",
	description = "Open a URL or reference",
	run = function(args)
		with_argument(args, "Open: ", require("atlas.commands.open").open)
	end,
})

M.register({
	name = "create-pr",
	description = "Create a pull request",
	run = function()
		require("atlas.pulls.create.pr").start()
	end,
})

M.register({
	name = "create-issue",
	description = "Create an issue",
	run = function()
		require("atlas.issues.create").start()
	end,
})

M.register({
	name = "diff",
	description = "Open native AtlasDiff",
	run = function(args)
		with_argument(args, "Git range or pull request: ", require("atlas.pulls.diff").open_argument)
	end,
})

M.register({
	name = "review",
	description = "Open or pick a pull request review",
	run = function(args)
		require("atlas.commands.review").open(args[1])
	end,
})

M.register({
	name = "notes",
	description = "Open local review notes",
	run = function(args)
		require("atlas.pulls.notes.ui").open({ target = args[1] })
	end,
})

M.register({
	name = "clear-notes",
	description = "Delete all local review notes",
	run = function()
		require("atlas.pulls.notes.ui").clear_all()
	end,
})

M.register({
	name = "clear-cache",
	description = "Clear Atlas cache",
	run = function()
		require("atlas.core.cache").clear_all()
		require("atlas.core.memory_cache").clear_all()
		notify.info("Cache cleared")
	end,
})

M.register({
	name = "logs",
	description = "Open Atlas logs",
	run = function()
		require("atlas.ui.logs").toggle()
	end,
})

local function pick_command()
	vim.ui.select(M.commands, {
		prompt = "Atlas:",
		format_item = function(command)
			return command.name .. "  " .. command.description
		end,
	}, function(command)
		if command then
			command.run({})
		end
	end)
end

---@param args string[]
function M.run(args)
	if #args == 0 then
		pick_command()
		return
	end

	local command = find_command(args[1]:lower())
	if command == nil then
		notify.error("Unknown command: " .. args[1])
		return
	end

	command.run(vim.list_slice(args, 2))
end

---@param arglead string
---@param cmdline string
---@return string[]
local function complete(arglead, cmdline)
	local words = vim.split(vim.trim(cmdline), "%s+")
	if #words < 2 or (#words == 2 and not cmdline:match("%s$")) then
		return vim.tbl_filter(
			function(name)
				return name:find(arglead, 1, true) == 1
			end,
			vim.tbl_map(function(command)
				return command.name
			end, M.commands)
		)
	end

	local command = find_command(words[2])
	return command and command.complete and command.complete(arglead) or {}
end

function M.setup()
	pcall(vim.api.nvim_del_user_command, "Atlas")
	pcall(vim.api.nvim_del_user_command, "AtlasDiff")

	vim.api.nvim_create_user_command("Atlas", function(opts)
		M.run(opts.fargs)
	end, {
		desc = "Open Atlas or run a command",
		nargs = "*",
		complete = complete,
	})

	vim.api.nvim_create_user_command("AtlasDiff", function(opts)
		require("atlas.pulls.diff").open_argument(opts.args)
	end, {
		desc = "Open a Git range or pull request in AtlasDiff",
		nargs = 1,
	})
end

return M
