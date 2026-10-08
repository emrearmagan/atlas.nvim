local M = {}

local config = require("atlas.config")
local keymaps = require("atlas.core.keymaps")
local notify = require("atlas.core.notify")
local providers = require("atlas.providers")

local labels = { merge = "Merge", squash = "Squash" }
local namespace = vim.api.nvim_create_namespace("atlas.pulls.merge")

---@class PullsMergeState
---@field pr PullRequest
---@field callbacks { on_submit: fun(options: PullsMergeOpts, completed: fun(ok: boolean)), on_cancel: fun() }
---@field options PullsMergeOpts
---@field drafts { merge: string, squash?: string }
---@field status "editing"|"loading"|"submitting"|"finished"
---@field buf integer
---@field footer string[]
---@field hints table<string, "method"|"delete_source_branch">

---@param pr PullRequest
---@return PullsMergeOpts
local function defaults(pr)
	local pulls = config.options.pulls
	---@cast pulls AtlasPullsConfig
	local settings = vim.tbl_get(pulls, "repo_config", "settings", pr.repo_full_name) or {}
	local delete_source_branch = settings.delete_source_branch
	if delete_source_branch == nil then
		delete_source_branch = pulls.default_delete_source_branch
	end
	return {
		method = (settings.merge_method or pulls.default_merge_method) == "squash" and "squash" or "merge",
		delete_source_branch = delete_source_branch == true,
	}
end

---@param pr PullRequest
---@param commits PullsCommit[]
---@return string
local function squash_message(pr, commits)
	if #commits == 0 then
		return pr.title
	end
	if #commits == 1 then
		local message = vim.trim(commits[1].message):gsub("\r\n", "\n")
		return message
	end
	local messages = {}
	-- Provider commit lists are newest first; compose the message oldest first.
	for i = #commits, 1, -1 do
		local text = vim.trim(commits[i].message):gsub("\r\n", "\n")
		messages[#messages + 1] = "* " .. text:gsub("\n([^\n])", "\n  %1")
	end
	return pr.title .. "\n\n" .. table.concat(messages, "\n")
end

---@param state PullsMergeState
---@return string
local function read_message(state)
	local lines = vim.tbl_filter(function(line)
		return line:sub(1, 1) ~= "#"
	end, vim.api.nvim_buf_get_lines(state.buf, 0, -1, false))
	return vim.trim(table.concat(lines, "\n"))
end

---@param state PullsMergeState
local function save_draft(state)
	vim.api.nvim_buf_call(state.buf, function()
		vim.cmd("silent write")
	end)
end

---@param state PullsMergeState
---@param message string|nil
local function render(state, message)
	if message then
		local lines = vim.split(message, "\n", { plain = true })
		vim.list_extend(lines, state.footer)
		vim.bo[state.buf].modifiable = true
		vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
		save_draft(state)
	end
	vim.bo[state.buf].modifiable = state.status == "editing"
	local values = {
		method = labels[state.options.method],
		delete_source_branch = state.options.delete_source_branch and "Yes" or "No",
	}
	if state.status == "submitting" then
		values.method = values.method .. " (merging...)"
	end
	vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
	for row, line in ipairs(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)) do
		local value = values[state.hints[line]]
		if value then
			vim.api.nvim_buf_set_extmark(state.buf, namespace, row - 1, 0, {
				virt_text = { { value } },
				virt_text_pos = "eol",
			})
		end
	end
end

---@param state PullsMergeState
local function load_message(state)
	local draft = state.drafts[state.options.method]
	if draft then
		state.status = "editing"
		render(state, draft)
		return
	end

	state.status = "loading"
	render(state, "Loading commit messages...")
	local core = providers.load(state.pr.provider, "pulls").capabilities.core
	core.fetch_commits(state.pr, { force_refresh = true }, function(commits, err)
		if not vim.api.nvim_buf_is_valid(state.buf) then
			return
		end
		state.drafts.squash = squash_message(state.pr, commits or {})
		state.status = "editing"
		render(state, state.drafts.squash)
		if err then
			notify.error("Could not load commit messages: " .. err .. ". Enter a message manually.")
		end
	end)
end

---@param state PullsMergeState
local function close(state)
	for _, win in ipairs(vim.fn.win_findbuf(state.buf)) do
		pcall(vim.api.nvim_win_close, win, true)
	end
	if vim.api.nvim_buf_is_valid(state.buf) then
		vim.api.nvim_buf_delete(state.buf, { force = true })
	end
end

---@param state PullsMergeState
local function submit(state)
	if state.status ~= "editing" then
		return
	end
	vim.cmd("stopinsert")
	save_draft(state)
	local lines = vim.split(read_message(state), "\n", { plain = true })
	local subject = vim.trim(table.remove(lines, 1) or "")
	if subject == "" then
		notify.warn("Commit title cannot be empty")
		return
	end
	if lines[1] == "" then
		table.remove(lines, 1)
	end
	local options = {
		method = state.options.method,
		delete_source_branch = state.options.delete_source_branch,
		subject = subject,
		body = table.concat(lines, "\n"),
	}
	local prompt = string.format("%s %s #%s?", labels[options.method], state.pr.repo_full_name, state.pr.id)
	if vim.fn.confirm(prompt, "&Yes\n&No", 2) ~= 1 then
		return
	end
	state.status = "submitting"
	render(state)
	state.callbacks.on_submit(options, function(ok)
		if not vim.api.nvim_buf_is_valid(state.buf) then
			state.status = "finished"
			if not ok then
				state.callbacks.on_cancel()
			end
			return
		end
		if ok then
			state.status = "finished"
			close(state)
		else
			state.status = "editing"
			render(state)
		end
	end)
end

---@param state PullsMergeState
local function cancel(state)
	if state.status ~= "submitting" then
		close(state)
	end
end

---@param state PullsMergeState
local function change_method(state)
	if state.status ~= "editing" then
		return
	end
	state.drafts[state.options.method] = read_message(state)
	state.options.method = state.options.method == "merge" and "squash" or "merge"
	load_message(state)
end

---@param state PullsMergeState
local function toggle_delete(state)
	if state.status ~= "submitting" then
		state.options.delete_source_branch = not state.options.delete_source_branch
		render(state)
	end
end

---@param state PullsMergeState
---@return integer win
local function setup_buffer(state)
	local path = vim.fn.tempname() .. "_COMMIT_EDITMSG"
	state.buf = vim.api.nvim_create_buf(false, false)
	vim.api.nvim_buf_set_name(state.buf, path)
	vim.bo[state.buf].bufhidden = "wipe"
	vim.bo[state.buf].swapfile = false
	vim.bo[state.buf].modeline = false
	vim.bo[state.buf].filetype = "gitcommit"
	vim.cmd("botright " .. math.max(14, math.floor(vim.o.lines * 0.5)) .. "split")
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, state.buf)
	for key, value in pairs({
		number = false,
		relativenumber = false,
		signcolumn = "no",
		diff = false,
		scrollbind = false,
		cursorbind = false,
		foldenable = false,
		wrap = true,
		linebreak = true,
		winbar = "",
	}) do
		vim.wo[win][key] = value
	end
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = state.buf,
		once = true,
		callback = function()
			vim.fn.delete(path)
			if state.status ~= "finished" and state.status ~= "submitting" then
				state.status = "finished"
				state.callbacks.on_cancel()
			end
		end,
	})
	return win
end

---@param state PullsMergeState
local function setup_keymaps(state)
	local bindings = {
		{
			keys = { "gm" },
			mode = "n",
			callback = change_method,
			desc = "Change merge method",
			label = "Method:",
			option = "method",
		},
		{
			keys = { "gd" },
			mode = "n",
			callback = toggle_delete,
			desc = "Toggle source branch deletion",
			label = "Delete source branch:",
			option = "delete_source_branch",
		},
		{ keys = keymaps.resolve("ui.submit") or {}, mode = { "n", "i" }, callback = submit, desc = "Merge" },
		{ keys = keymaps.resolve("ui.close") or {}, mode = "n", callback = cancel, desc = "Cancel" },
	}
	state.footer = {
		"",
		"",
		"# Edit the title above and add an optional description.",
		"#",
		string.format(
			"# %s #%s · %s → %s",
			state.pr.repo_full_name,
			state.pr.id,
			state.pr.source.branch,
			state.pr.destination.branch
		),
		"#",
	}
	state.hints = {}
	for _, binding in ipairs(bindings) do
		for _, key in ipairs(binding.keys) do
			vim.keymap.set(binding.mode, key, function()
				binding.callback(state)
			end, { buffer = state.buf, silent = true, nowait = true, desc = binding.desc })
		end
		if #binding.keys > 0 then
			local line = string.format("# %-8s %s", table.concat(binding.keys, "/"), binding.label or binding.desc)
			state.footer[#state.footer + 1] = line
			if binding.option then
				state.hints[line] = binding.option
			end
		end
	end
	vim.list_extend(state.footer, { "#", "# Lines starting with '#' will be ignored." })
end

---@param pr PullRequest
---@param callbacks { on_submit: fun(options: PullsMergeOpts, completed: fun(ok: boolean)), on_cancel: fun() }
---@return integer buf, integer win
function M.open(pr, callbacks)
	local state = {
		pr = pr,
		callbacks = callbacks,
		options = defaults(pr),
		drafts = { merge = pr.title },
		status = "editing",
	}
	local win = setup_buffer(state)
	setup_keymaps(state)
	load_message(state)
	vim.api.nvim_win_set_cursor(win, { 1, 0 })
	return state.buf, win
end

return M
