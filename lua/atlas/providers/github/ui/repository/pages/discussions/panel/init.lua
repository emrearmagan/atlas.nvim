local notify = require("atlas.core.notify")
local requests = require("atlas.core.requests")
local discussions = require("atlas.providers.github.discussions")
local keymaps = require("atlas.providers.github.ui.repository.pages.discussions.panel.keymaps")
local renderer = require("atlas.providers.github.ui.repository.pages.discussions.panel.renderer")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

---@class GitHubDiscussionPanel
---@field win integer
---@field buf integer
---@field anchor integer
---@field repo AtlasRepositoryDetails
---@field statusline AtlasStatusline
---@field number integer
---@field discussion GitHubDiscussionDetails|"loading"|string
---@field expanded table<string, boolean>
---@field line_map table<integer, AtlasThreadLineMap>
---@field requests AtlasRequestScope
---@field group integer

local M = {}
local namespace = vim.api.nvim_create_namespace("atlas.repository.discussions.panel")

---@param win integer
local function configure(win)
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].foldcolumn = "0"
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].cursorline = true
end

---@param panel GitHubDiscussionPanel
local function render(panel)
	if not utils.buffer.valid(panel.buf) or not utils.window.valid(panel.win) then
		return
	end

	local lines, spans, line_map =
		renderer.render(panel.discussion, panel.expanded, vim.api.nvim_win_get_width(panel.win))
	panel.line_map = line_map
	local winbar = ""
	if type(panel.discussion) == "table" then
		local bell, hl = icons.get("bell_no")
		if panel.discussion.subscribed then
			bell, hl = icons.get("bell"), "AtlasLogInfo"
		end

		winbar = string.format("%%=%%#%s#%s%%* ", hl, bell)
	end

	vim.wo[panel.win].winbar = winbar
	vim.bo[panel.buf].modifiable = true
	vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
	vim.bo[panel.buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(panel.buf, namespace, 0, -1)
	for _, span in ipairs(spans) do
		if span.line_hl_group then
			vim.api.nvim_buf_set_extmark(panel.buf, namespace, span.line, 0, { line_hl_group = span.line_hl_group })
		else
			vim.api.nvim_buf_set_extmark(panel.buf, namespace, span.line, span.start_col, {
				end_col = span.end_col,
				hl_group = span.hl_group,
			})
		end
	end
end

---@param panel GitHubDiscussionPanel
local function load(panel)
	panel.requests.cancel()
	panel.requests = requests.new()
	panel.discussion = "loading"
	panel.statusline:notify("loading", "Loading discussion...")
	render(panel)

	panel.requests.run(function(done)
		return discussions.fetch_discussion(panel.repo, panel.number, done)
	end, function(discussion, err)
		panel.statusline:clear_notice()
		panel.discussion = discussion or err or "Unable to load discussion"
		render(panel)
	end)
end

---@param panel GitHubDiscussionPanel
---@return AtlasThreadLineMap|nil
local function current(panel)
	return panel.line_map[vim.api.nvim_win_get_cursor(panel.win)[1]]
end

---@param panel GitHubDiscussionPanel
local function toggle_fold(panel)
	local entry = current(panel)
	local root = entry and entry.root
	if root and #root.replies > 0 then
		panel.expanded[root.id] = not panel.expanded[root.id]
		render(panel)
	end
end

---@param panel GitHubDiscussionPanel
local function open_in_browser(panel)
	if type(panel.discussion) == "table" then
		vim.ui.open(panel.discussion.url)
	end
end

---@param panel GitHubDiscussionPanel
local function copy_url(panel)
	if type(panel.discussion) == "table" then
		vim.fn.setreg("+", panel.discussion.url)
		notify.success("Copied URL")
	end
end

---@param opts { anchor: integer, repo: AtlasRepositoryDetails, statusline: AtlasStatusline, number: integer }
---@return GitHubDiscussionPanel
local function create(opts)
	local tab = vim.api.nvim_get_current_tabpage()
	local buf = utils.buffer.create("atlas://repository/" .. tab .. "/discussion", "atlas-ui.detail")
	vim.bo[buf].bufhidden = "wipe"
	local win = utils.window.create(opts.anchor, "botright vsplit", buf, configure)
	pcall(vim.api.nvim_win_set_width, win, math.max(math.floor(vim.o.columns * 0.45), 40))
	opts.statusline:attach(win)

	---@type GitHubDiscussionPanel
	local panel = {
		win = win,
		buf = buf,
		anchor = opts.anchor,
		repo = opts.repo,
		statusline = opts.statusline,
		number = opts.number,
		discussion = "loading",
		expanded = {},
		line_map = {},
		requests = requests.new(),
		group = vim.api.nvim_create_augroup("AtlasRepositoryDiscussionPanel" .. buf, { clear = true }),
	}

	keymaps.setup(panel, {
		close = M.close,
		copy_url = copy_url,
		current = current,
		load = load,
		open_in_browser = open_in_browser,
		render = render,
		toggle_fold = toggle_fold,
	})
	vim.api.nvim_create_autocmd("WinResized", {
		group = panel.group,
		callback = function()
			if vim.tbl_contains(vim.v.event.windows, panel.win) then
				render(panel)
			end
		end,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		group = panel.group,
		pattern = tostring(win),
		once = true,
		callback = function()
			M.close(panel)
		end,
	})

	return panel
end

---@param panel GitHubDiscussionPanel|nil
---@param opts { anchor: integer, repo: AtlasRepositoryDetails, statusline: AtlasStatusline, number: integer }
---@return GitHubDiscussionPanel
function M.open(panel, opts)
	if panel and utils.window.valid(panel.win) then
		panel.number = opts.number
		panel.expanded = {}
	else
		panel = create(opts)
	end

	vim.api.nvim_set_current_win(panel.win)
	load(panel)
	return panel
end

---@param panel GitHubDiscussionPanel|nil
function M.close(panel)
	if not panel or not panel.group then
		return
	end

	local group = panel.group
	panel.group = nil
	panel.requests.cancel()
	panel.statusline:clear_notice()
	vim.api.nvim_del_augroup_by_id(group)
	if utils.window.valid(panel.win) then
		vim.api.nvim_win_close(panel.win, true)
	end

	if utils.window.valid(panel.anchor) then
		vim.api.nvim_set_current_win(panel.anchor)
	end
end

return M
