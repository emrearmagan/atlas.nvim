local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")
local providers = require("atlas.providers")
local ui_utils = require("atlas.ui.utils")

local M = {}

---@class AtlasCommand
---@field name string
---@field usage string|nil
---@field description string
---@field run fun(args: string[]): boolean|nil Return false for invalid arguments to show the usage.
---@field complete (fun(arglead: string, args?: string[]): string[])|nil
---@field choices (fun(): { args: string[], description: string }[])|nil

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

---@param args string[]
---@return AtlasCommand|nil, string[]
local function find_command(args)
	for _, command in ipairs(M.commands) do
		local words = vim.split(command.name, " ")
		if vim.deep_equal(words, vim.tbl_map(string.lower, vim.list_slice(args, 1, #words))) then
			return command, vim.list_slice(args, #words + 1)
		end
	end
	return nil, {}
end

---@param arglead string
---@param options string[]
---@return string[]
local function complete_options(arglead, options)
	return vim.tbl_filter(function(option)
		return option:find(arglead, 1, true) == 1
	end, options)
end

---@param domain "pulls"|"issues"
---@param arglead string
---@return string[]
local function complete_providers(domain, arglead)
	local ids = {}
	for _, provider in ipairs(providers.configured(domain)) do
		table.insert(ids, provider.id)
	end
	return complete_options(arglead, ids)
end

---@param domain "pulls"|"issues"
---@return { args: string[], description: string }[]
local function provider_choices(domain)
	local label = domain == "pulls" and "pull requests" or "issues"
	local choices = { { args = { "." }, description = "Open " .. label .. " with the current repository's provider" } }
	for _, provider in ipairs(providers.configured(domain)) do
		local description = string.format("Open %s %s", provider.name, label)
		table.insert(choices, { args = { provider.id }, description = description })
	end
	return choices
end

M.register({
	name = "pulls",
	description = "Open pull requests",
	choices = function()
		return provider_choices("pulls")
	end,
	complete = function(arglead, args)
		if #args > 1 then
			return {}
		end
		return vim.list_extend(complete_options(arglead, { "." }), complete_providers("pulls", arglead))
	end,
	run = function(args)
		require("atlas.commands.dashboard").open("pulls", args[1])
	end,
})

M.register({
	name = "issues",
	description = "Open issues",
	choices = function()
		return provider_choices("issues")
	end,
	complete = function(arglead, args)
		if #args > 1 then
			return {}
		end
		return vim.list_extend(complete_options(arglead, { "." }), complete_providers("issues", arglead))
	end,
	run = function(args)
		require("atlas.commands.dashboard").open("issues", args[1])
	end,
})

M.register({
	name = "search",
	description = "Search across providers",
	choices = function()
		local choices = { { args = { "." }, description = "Search the current repository's provider" } }
		for _, provider_id in ipairs(require("atlas.commands.search").complete("")) do
			table.insert(choices, { args = { provider_id }, description = "Search " .. providers[provider_id].name })
		end
		return choices
	end,
	complete = function(arglead, args)
		if #args > 1 then
			return {}
		end
		return vim.list_extend(complete_options(arglead, { "." }), require("atlas.commands.search").complete(arglead))
	end,
	run = function(args)
		require("atlas.commands.search").run(args[1] and args[1]:lower() or nil)
	end,
})

M.register({
	name = "open",
	description = "Open a pull request or issue",
	choices = function()
		return {
			{ args = {}, description = "Open a pull request or issue" },
			{ args = { "." }, description = "Open the current branch's pull request" },
		}
	end,
	complete = function(arglead, args)
		if #args > 1 then
			return {}
		end
		return complete_options(arglead, { "." })
	end,
	run = function(args)
		require("atlas.commands.open").open(args[1])
	end,
})

M.register({
	name = "browse",
	usage = "browse [repository URL|.|page] [page]",
	description = "Open the repository browser",
	complete = function(arglead, args)
		return require("atlas.commands.browse").complete(arglead, args)
	end,
	run = function(args)
		if #args > 2 then
			return false
		end
		require("atlas.commands.browse").open(args[1], args[2])
	end,
})

M.register({
	name = "create pr",
	description = "Create a pull request",
	run = function()
		require("atlas.pulls.editor").open()
	end,
})

M.register({
	name = "create issue",
	description = "Create an issue",
	choices = function()
		return {
			{ args = {}, description = "Create an issue" },
			{ args = { "." }, description = "Create an issue with the current repository's provider" },
		}
	end,
	complete = function(arglead, args)
		if #args > 1 then
			return {}
		end
		return vim.list_extend(complete_options(arglead, { "." }), complete_providers("issues", arglead))
	end,
	run = function(args)
		require("atlas.commands.create").issue(args[1])
	end,
})

M.register({
	name = "diff",
	usage = "diff <base...head>",
	description = "Open a Git range diff",
	complete = function(arglead, args)
		return require("atlas.commands.diff").complete(arglead, args)
	end,
	run = function(args)
		local value = vim.trim(table.concat(args, " "))
		if value == "" then
			return false
		end
		require("atlas.commands.diff").open(value)
	end,
})

M.register({
	name = "pipelines",
	usage = "pipelines [target|.]",
	description = "Open branch, pull request, or build pipelines",
	complete = function(arglead)
		return require("atlas.commands.pipelines").complete(arglead)
	end,
	run = function(args)
		require("atlas.commands.pipelines").open(args[1])
	end,
})

M.register({
	name = "review",
	description = "Review a pull request",
	choices = function()
		return {
			{ args = {}, description = "Review a pull request" },
			{ args = { "." }, description = "Review the current branch's pull request" },
		}
	end,
	complete = function(arglead, args)
		if #args > 1 then
			return {}
		end
		return complete_options(arglead, { "." })
	end,
	run = function(args)
		require("atlas.commands.review").open(args[1])
	end,
})

M.register({
	name = "notes",
	description = "Open review notes",
	choices = function()
		return {
			{ args = {}, description = "Open review notes" },
			{ args = { "." }, description = "Open review notes for the current repository" },
		}
	end,
	complete = function(arglead, args)
		if #args > 1 then
			return {}
		end
		return vim.list_extend(complete_options(arglead, { "." }), require("atlas.pulls.notes").complete(arglead, args))
	end,
	run = function(args)
		require("atlas.commands.notes").open(args[1])
	end,
})

M.register({
	name = "clear",
	usage = "clear [cache|notes|reviewed|stars]",
	description = "Clear Atlas data, caches, notes, reviewed file marks, or starred items",
	choices = function()
		return {
			{ args = {}, description = "Clear caches, clones, notes, reviewed file marks, stars, and logs" },
			{ args = { "cache" }, description = "Clear caches and cloned repositories" },
			{ args = { "notes" }, description = "Clear review notes" },
			{ args = { "reviewed" }, description = "Clear reviewed file marks" },
			{ args = { "stars" }, description = "Clear starred items" },
		}
	end,
	complete = function(arglead)
		return complete_options(arglead, { "cache", "notes", "reviewed", "stars" })
	end,
	run = function(args)
		return require("atlas.commands.clear").run(args[1] and args[1]:lower() or nil)
	end,
})

M.register({
	name = "console",
	description = "Open the latest command output",
	run = function()
		require("atlas.ui.console").open()
	end,
})

M.register({
	name = "logs",
	description = "Toggle Atlas logs",
	run = function()
		require("atlas.ui.logs").toggle()
	end,
})

---@param command AtlasCommand
---@param args string[]
local function run_command(command, args)
	if command.run(args) == false then
		notify.error("Usage: :Atlas " .. (command.usage or command.name), { vim_notify = true })
	end
end

local function pick_command()
	---@type { command: AtlasCommand, args: string[], label: string, description: string }[]
	local choices = {}
	for _, command in ipairs(M.commands) do
		local entries = command.choices and command.choices() or { { args = {}, description = command.description } }
		for _, choice in ipairs(entries) do
			table.insert(choices, {
				command = command,
				args = choice.args,
				label = vim.trim(command.name .. " " .. table.concat(choice.args, " ")),
				description = choice.description,
			})
		end
	end

	local label_width = 0
	for _, choice in ipairs(choices) do
		label_width = math.max(label_width, vim.fn.strdisplaywidth(choice.label))
	end

	picker.select({
		title = "Atlas:",
		items = choices,
		format_item = function(choice)
			return ui_utils.pad_right(choice.label, label_width) .. "  " .. choice.description
		end,
		on_select = function(choice)
			if choice then
				run_command(choice.command, choice.args)
			end
		end,
	})
end

---@param args string[]
function M.run(args)
	if #args == 0 then
		pick_command()
		return
	end

	local command, command_args = find_command(args)
	if command == nil then
		notify.error("Unknown command: " .. table.concat(args, " "), { vim_notify = true })
		return
	end

	run_command(command, command_args)
end

---@param arglead string
---@param cmdline string
---@param cursorpos integer
---@return string[]
local function complete(arglead, cmdline, cursorpos)
	local words = vim.split(cmdline:sub(1, cursorpos):gsub("^%s+", ""), "%s+")
	table.remove(words, 1)
	local command, args = find_command(words)
	if command and #args > 0 then
		return command.complete and command.complete(arglead, args) or {}
	end

	local typed = table.concat(words, " "):lower()
	local names = {}
	for _, candidate in ipairs(M.commands) do
		local name = vim.split(candidate.name, " ")[#words]
		if candidate.name:find(typed, 1, true) == 1 and not vim.tbl_contains(names, name) then
			table.insert(names, name)
		end
	end
	return names
end

function M.setup()
	pcall(vim.api.nvim_del_user_command, "Atlas")

	vim.api.nvim_create_user_command("Atlas", function(opts)
		M.run(opts.fargs)
	end, {
		desc = "Open Atlas or run a command",
		nargs = "*",
		complete = complete,
	})
end

return M
