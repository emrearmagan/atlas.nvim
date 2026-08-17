local M = {}

local icons = require("atlas.ui.shared.icons")
local header = require("atlas.pulls.ui.panel.components.header")
local request_scope = require("atlas.core.requests")
local spinner = require("atlas.ui.components.spinner")

local MAX_HASH_LEN = 12

---@param pullrequests table
---@return PullsProviderPRPanel
function M.new(pullrequests)
	local panel = {}

	---@param pr PullRequest
	---@param loading boolean
	---@return PullsPanelHeaderRow[]
	function panel.header_rows(pr, loading)
		if loading and pr.assignees == nil then
			return {
				{
					k1 = "Assignees:",
					v1 = spinner.with_text("Loading..."),
					v1_hl = "AtlasTextMuted",
					k2 = "",
					v2 = "",
					v2_hl = "AtlasTextMuted",
				},
			}
		end
		local logins = {}
		for _, assignee in ipairs(pr.assignees or {}) do
			local login = tostring(assignee.username or "")
			if login ~= "" then
				table.insert(logins, login)
			end
		end
		local rows = { header.assignee_row(logins) }
		return rows
	end

	---@param hex string
	---@return string
	local function label_hl(hex)
		hex = tostring(hex or ""):gsub("^#", "")
		if not hex:match("^%x%x%x%x%x%x$") then
			return "AtlasTabInactive"
		end
		local name = "AtlasGiteaLabel_" .. hex
		vim.api.nvim_set_hl(0, name, { fg = "#1e1e2e", bg = "#" .. hex, bold = true })
		return name
	end

	---@param pr PullRequest
	---@param _loading boolean
	---@return PullsPanelChip[]
	function panel.chips(pr, _loading)
		local chips = {}
		local hash = tostring(type(pr.source) == "table" and pr.source.commit_hash or "")
		if hash ~= "" then
			table.insert(chips, { label = hash:sub(1, MAX_HASH_LEN), hl = "AtlasTabInactive" })
		end
		for _, label in ipairs(pr.labels or {}) do
			if label.name ~= "" then
				table.insert(chips, { label = label.name, hl = label_hl(label.color or "") })
			end
		end
		return chips
	end

	---@param pr PullRequest
	---@param opts { force_refresh: boolean|nil, pr_refreshed: boolean|nil }|nil
	---@param on_done fun()
	---@return { cancel: fun() }|nil
	function panel.fetch_header(pr, opts, on_done)
		local starts = {}
		if not (opts and opts.pr_refreshed) then
			starts.pull = function(done)
				return pullrequests.get(pr, { force_refresh = opts and opts.force_refresh }, done)
			end
		end
		starts.subscription = function(done)
			return pullrequests.subscription(pr, done)
		end
		local requests = request_scope.new()
		requests.all(starts, function(values)
			local fresh = values.pull
			if type(fresh) == "table" then
				for _, field in ipairs({
					"assignees",
					"reviewers",
					"labels",
					"reactions",
				}) do
					pr[field] = fresh[field]
				end
				pr._raw = fresh._raw
			end
			if type(values.subscription) == "boolean" then
				pr.is_subscribed = values.subscription
			end
			on_done()
		end)
		return requests
	end

	---@return PullsPRPanelTab[]
	function panel.tabs()
		local overview_icon, overview_hl = icons.general("overview")
		local conversation_icon, conversation_hl = icons.general("conversation")
		local review_icon, review_hl = icons.pulls("review")
		local commit_icon, commit_hl = icons.pulls("commit")
		return {
			{
				key = "overview",
				label = "Overview",
				icon = overview_icon,
				icon_hl = overview_hl,
				mod = require("atlas.pulls.ui.panel.pr.tabs.overview"),
				keymaps = require("atlas.pulls.providers.gitea.ui.overview_keymaps"),
			},
			{
				key = "conversation",
				label = "Conversation",
				icon = conversation_icon,
				icon_hl = conversation_hl,
				mod = require("atlas.pulls.ui.panel.pr.tabs.conversation"),
			},
			{
				key = "review",
				label = "Review",
				icon = review_icon,
				icon_hl = review_hl,
				mod = require("atlas.pulls.ui.panel.pr.tabs.review"),
			},
			{
				key = "commits",
				label = "Commits",
				icon = commit_icon,
				icon_hl = commit_hl,
				mod = require("atlas.pulls.ui.panel.pr.tabs.commits"),
			},
		}
	end

	return panel
end

return M
