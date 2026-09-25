local resolver = require("atlas.core.keymaps")
local notify = require("atlas.core.notify")
local request_scope = require("atlas.core.requests")
local loading = require("atlas.ui.loading")
local pages = require("atlas.ui.repository.pages")
local keymaps = require("atlas.ui.repository.keymaps")
local navigation = require("atlas.ui.repository.navigation")
local statusline = require("atlas.ui.statusline")
local utils = require("atlas.ui.shared.utils")

---@class RepositoryBrowser
---@field tab integer
---@field group integer
---@field closed boolean
---@field navigation RepositoryNavigation
---@field content { buf: integer, win: integer }
---@field repo AtlasRepositoryDetails
---@field provider PullsProvider|IssuesProvider
---@field page RepositoryPage|nil
---@field statusline AtlasStatusline

local M = {}

---@param win integer
local function setup_window(win)
	for option, value in pairs({
		number = false,
		relativenumber = false,
		signcolumn = "no",
		statuscolumn = "",
		foldcolumn = "0",
		foldenable = false,
		wrap = false,
		cursorline = false,
		conceallevel = 0,
		concealcursor = "",
	}) do
		vim.api.nvim_set_option_value(option, value, { win = win })
	end
end

---@param session RepositoryBrowser
local function setup_buffers(session)
	local prefix = "atlas://repository/" .. session.tab
	session.navigation.buf = utils.buffer.create(prefix .. "/navigation", "atlas.repository")
	session.content.buf = utils.buffer.create(prefix .. "/content", "atlas.repository")
end

---@param session RepositoryBrowser
local function setup_windows(session)
	local placeholder = vim.api.nvim_get_current_buf()
	session.content.win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(session.content.win, session.content.buf)
	utils.buffer.delete(placeholder)
	setup_window(session.content.win)
	session.statusline:attach(session.content.win)
	vim.wo[session.content.win].winbar = ""
	local nav = session.navigation
	nav.win = vim.api.nvim_open_win(nav.buf, false, {
		split = "above",
		win = session.content.win,
		height = 1,
	})
	setup_window(nav.win)
	vim.wo[nav.win].winfixheight = true
	vim.wo[nav.win].winbar = ""
	if vim.o.laststatus == 3 then
		session.statusline:attach(nav.win)
	else
		vim.wo[nav.win].statusline = "%#WinSeparator#"
	end
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
			for _, pane in ipairs({ session.navigation, session.content }) do
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
	utils.buffer.delete(session.navigation.buf)
	utils.buffer.delete(session.content.buf)
end

---@param session RepositoryBrowser
---@param index integer
local function select_page(session, index)
	local page = session.navigation.pages[index]
	if session.page == page then
		return
	end
	if session.page then
		local previous_buf = session.content.buf
		session.page.close(previous_buf)
		session.content.buf =
			utils.buffer.create("atlas://repository/" .. session.tab .. "/content/" .. page.key, "atlas.repository")
		vim.api.nvim_win_set_buf(session.content.win, session.content.buf)
		utils.buffer.delete(previous_buf)
	end
	session.page = page
	session.navigation.selected = index
	navigation.render(session.navigation)
	navigation.focus(session.navigation)
	setup_window(session.content.win)
	session.statusline:attach(session.content.win)
	vim.wo[session.content.win].winbar = page.label:gsub("%%", "%%%%")
	vim.api.nvim_win_set_cursor(session.content.win, { 1, 0 })
	keymaps.setup(session, function()
		close(session)
	end, function(next_index)
		select_page(session, next_index)
	end)
	page.open({
		buf = session.content.buf,
		win = session.content.win,
		navigation_buf = session.navigation.buf,
		repo = session.repo,
		provider = session.provider,
		statusline = session.statusline,
	})
end

---@param session RepositoryBrowser
local function setup_events(session)
	session.group = vim.api.nvim_create_augroup("AtlasRepository" .. session.tab, { clear = true })
	vim.api.nvim_create_autocmd("WinClosed", {
		group = session.group,
		pattern = { tostring(session.navigation.win), tostring(session.content.win) },
		callback = function()
			vim.schedule(function()
				close(session)
			end)
		end,
	})
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
		group = session.group,
		callback = function()
			if utils.window.valid(session.navigation.win) then
				navigation.render(session.navigation)
				navigation.focus(session.navigation)
			end
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
		navigation = { pages = pages.get(provider), selected = 1, positions = {} },
		content = {},
		statusline = statusline.new({ help_key = (resolver.resolve("ui.help") or {})[1] }),
	}
	---@cast session RepositoryBrowser
	setup_buffers(session)
	setup_windows(session)
	setup_events(session)
	session.statusline:set_items({
		{ text = provider.name .. " / " .. (repo.full_name or repo.name), hl_group = "AtlasFooterText" },
	})
	for index, page in ipairs(session.navigation.pages) do
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
	local owner, name = repo_full_name:match("^(.+)/([^/]+)$")
	if not owner or not name then
		notify.error("Repository must use owner/name")
		return
	end
	local repo = { id = repo_full_name, full_name = repo_full_name, name = name, owner = owner, repo_name = name }
	local requests = request_scope.new()
	local view = loading.open("Loading repository...", requests.cancel)
	requests.run(function(done)
		return repository.fetch_details(repo, done)
	end, function(details, err)
		if not details then
			view:finish()
			notify.error(err or "Failed to load repository")
			return
		end
		show(details, provider, opts and opts.page)
		view:finish()
	end)
end

return M
