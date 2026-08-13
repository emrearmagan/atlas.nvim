local M = {}

local notify = require("atlas.core.notify")

---@class AtlasCommand
---@field name string
---@field usage string|nil
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

---@param arglead string
---@param options string[]
---@return string[]
local function complete_options(arglead, options)
	return vim.tbl_filter(function(option)
		return option:find(arglead, 1, true) == 1
	end, options)
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
	name = "create",
	usage = "create <pr|issue>",
	description = "Create a pull request or issue",
	complete = function(arglead)
		return complete_options(arglead, { "pr", "issue" })
	end,
	run = function(args)
		local function start(kind)
			if kind == "pr" then
				require("atlas.pulls.create.pr").start()
			elseif kind == "issue" then
				require("atlas.issues.create").start()
			else
				notify.error("Usage: :Atlas create <pr|issue>")
			end
		end

		if args[1] then
			start(args[1]:lower())
		else
			vim.ui.select({ "pr", "issue" }, { prompt = "Create:" }, start)
		end
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
	name = "clear",
	usage = "clear [notes]",
	description = "Clear Atlas data or local notes",
	complete = function(arglead)
		return complete_options(arglead, { "notes" })
	end,
	run = function(args)
		local target = args[1] and args[1]:lower() or nil
		if target == "notes" then
			require("atlas.pulls.notes.ui").clear_all()
			return
		end
		if target then
			notify.error("Usage: :Atlas clear [notes]")
			return
		end

		vim.ui.input(
			{ prompt = "Delete Atlas caches, cloned repositories, local notes, and logs? [y/N]: " },
			function(answer)
				answer = vim.trim(tostring(answer or "")):lower()
				if answer ~= "y" and answer ~= "yes" then
					return
				end
				local cleared, err = require("atlas.pulls.notes").clear_all()
				if not cleared then
					notify.error(err or "Unable to delete local notes")
					return
				end
				require("atlas.core.cache").clear_all()
				require("atlas.core.memory_cache").clear_all()
				require("atlas.ui.components.async_picker").clear_cache()
				require("atlas.core.logger").clear()
				local notes_ui = package.loaded["atlas.pulls.notes.ui"]
				if notes_ui then
					notes_ui.refresh()
				end
				notify.info("Atlas data cleared")
			end
		)
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
			return (command.usage or command.name) .. "  " .. command.description
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
