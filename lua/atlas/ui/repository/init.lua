local resolver = require("atlas.core.keymaps")
local notify = require("atlas.core.notify")
local request_scope = require("atlas.core.requests")
local loading = require("atlas.ui.loading")
local pages = require("atlas.ui.repository.pages")
local keymaps = require("atlas.ui.repository.keymaps")
local sidebar = require("atlas.ui.repository.sidebar")
local statusline = require("atlas.ui.statusline")
local utils = require("atlas.ui.shared.utils")

---@class RepositoryBrowser
---@field tab integer
---@field group integer
---@field closed boolean
---@field sidebar RepositorySidebar
---@field content { buf: integer, win: integer }
---@field repo AtlasRepositoryDetails
---@field provider PullsProvider|IssuesProvider
---@field page RepositoryPage|nil
---@field statusline AtlasStatusline

local M = {}

---@param session RepositoryBrowser
---@param index integer
local function select_page(session, index)
	local page = session.sidebar.pages[index]
	if session.page == page then
		return
	end
	if session.page then
		session.page.close(session.content.buf)
	end
	session.page = page
	session.sidebar.selected = index
	sidebar.render(session.sidebar)
	vim.api.nvim_win_set_cursor(session.sidebar.win, { index, 0 })
	vim.wo[session.content.win].winbar = page.label
	vim.bo[session.content.buf].modifiable = true
	vim.api.nvim_buf_set_lines(session.content.buf, 0, -1, false, {})
	vim.bo[session.content.buf].modifiable = false
	vim.api.nvim_win_set_cursor(session.content.win, { 1, 0 })
	page.open({
		buf = session.content.buf,
		win = session.content.win,
		sidebar_buf = session.sidebar.buf,
		repo = session.repo,
		provider = session.provider,
		statusline = session.statusline,
	})
end

---@param session RepositoryBrowser
local function setup_buffers(session)
	local prefix = "atlas://repository/" .. session.tab
	session.sidebar.buf = utils.buffer.create(prefix .. "/sidebar", "atlas.repository")
	session.content.buf = utils.buffer.create(prefix .. "/content", "atlas.repository")
end

---@param session RepositoryBrowser
local function setup_windows(session)
	local placeholder = vim.api.nvim_get_current_buf()
	session.content.win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(session.content.win, session.content.buf)
	utils.buffer.delete(placeholder)
	session.sidebar.win = vim.api.nvim_open_win(session.sidebar.buf, true, {
		split = "left",
		win = session.content.win,
		width = math.min(22, math.max(14, math.floor(vim.o.columns * 0.2))),
	})
	for _, pane in ipairs({ session.sidebar, session.content }) do
		for option, value in pairs({
			number = false,
			relativenumber = false,
			signcolumn = "no",
			statuscolumn = "",
			foldcolumn = "0",
			foldenable = false,
			wrap = false,
			cursorline = false,
		}) do
			vim.api.nvim_set_option_value(option, value, { win = pane.win })
		end
		session.statusline:attach(pane.win)
	end
	vim.wo[session.sidebar.win].winfixwidth = true
	vim.wo[session.sidebar.win].cursorline = true
	vim.wo[session.sidebar.win].winbar = "Repository"
	vim.wo[session.content.win].winbar = ""
end

---@param session RepositoryBrowser
local function close(session)
	if session.closed then
		return
	end
	session.closed = true
	vim.api.nvim_del_augroup_by_id(session.group)
	if session.page then
		session.page.close(session.content.buf)
	end
	session.statusline:dispose()
	if utils.tab.valid(session.tab) then
		if #vim.api.nvim_list_tabpages() > 1 then
			vim.cmd(vim.api.nvim_tabpage_get_number(session.tab) .. "tabclose")
		else
			for _, pane in ipairs({ session.sidebar, session.content }) do
				if utils.window.valid(pane.win) then
					if #vim.api.nvim_tabpage_list_wins(session.tab) > 1 then
						vim.api.nvim_win_close(pane.win, true)
					else
						vim.api.nvim_win_set_buf(pane.win, vim.api.nvim_create_buf(true, false))
					end
				end
			end
		end
	end
	utils.buffer.delete(session.sidebar.buf)
	utils.buffer.delete(session.content.buf)
end

---@param session RepositoryBrowser
local function setup_events(session)
	session.group = vim.api.nvim_create_augroup("AtlasRepository" .. session.tab, { clear = true })
	vim.api.nvim_create_autocmd("WinClosed", {
		group = session.group,
		pattern = { tostring(session.sidebar.win), tostring(session.content.win) },
		callback = function()
			vim.schedule(function()
				close(session)
			end)
		end,
	})
end

---@param repo AtlasRepositoryDetails
---@param provider PullsProvider|IssuesProvider
---@param page_key string|nil
local function show(repo, provider, page_key)
	vim.cmd("tabnew")
	local session = {
		tab = vim.api.nvim_get_current_tabpage(),
		closed = false,
		repo = repo,
		provider = provider,
		sidebar = { pages = pages.get(provider), selected = 1 },
		content = {},
		statusline = statusline.new({ help_key = (resolver.resolve("ui.help") or {})[1] }),
	}
	---@cast session RepositoryBrowser
	setup_buffers(session)
	setup_windows(session)
	setup_events(session)
	keymaps.setup(session, function()
		close(session)
	end, function(index)
		select_page(session, index)
	end)
	session.statusline:set_items({
		{ text = provider.name .. " / " .. (repo.full_name or repo.name), hl_group = "AtlasFooterText" },
	})
	for index, page in ipairs(session.sidebar.pages) do
		if page.key == (page_key or "overview") then
			select_page(session, index)
			return
		end
	end
	select_page(session, 1)
end

---@param repo_full_name string
---@param provider PullsProvider|IssuesProvider
---@param opts { page?: string }|nil
function M.open(repo_full_name, provider, opts)
	local repository = provider.capabilities.repository
	if not repository then
		notify.error("Repository details are not available")
		return
	end
	local owner, name = repo_full_name:match("^(.*)/([^/]+)$")
	local repo = { id = repo_full_name, full_name = repo_full_name, name = name, owner = owner, repo_name = name }
	local requests = request_scope.new()
	local view = loading.open("Loading repository...", requests.cancel)
	requests.run(function(done)
		return repository.fetch_details(repo, {}, done)
	end, function(details, err)
		view:finish()
		if not details then
			notify.error(err or "Failed to load repository")
			return
		end
		show(details, provider, opts and opts.page)
	end)
end

return M
