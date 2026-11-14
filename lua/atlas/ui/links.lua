local M = {}

local config = require("atlas.config")
local icons = require("atlas.ui.shared.icons")
local notify = require("atlas.core.notify")
local open = require("atlas.commands.open")
local picker_format = require("atlas.ui.picker.format")
local providers = require("atlas.providers")
local request_scope = require("atlas.core.requests")

local fetch_requests = request_scope.new()

---@type table<AtlasRelationship, string>
local relationship_highlights = {
	closes = "AtlasTextPositive",
	["closed by"] = "AtlasTextPositive",
	blocks = "AtlasTextWarning",
	["blocked by"] = "AtlasTextWarning",
	["is blocked by"] = "AtlasTextWarning",
	parent = "AtlasLogInfo",
	["sub-issue"] = "AtlasLogInfo",
	child = "AtlasLogInfo",
}

---@param link AtlasLink
---@param err string|nil
---@return AtlasPickerPreview
local function link_preview(link, err)
	local title = (link.title or link.key or link.url):gsub("%c", " ")
	local lines = { "# " .. title, "", "**URL:** " .. link.url }

	if err then
		vim.list_extend(lines, { "", "> Could not load: " .. err:gsub("%c", " ") })
	end
	return { title = link.key or title, lines = lines }
end

---@param link AtlasLink
---@param done fun(preview: AtlasPickerPreview)
---@param width integer
---@return { cancel: fun() }|nil
local function preview(link, done, width)
	local target = providers.resolve(link.url)
	local provider = target
		and config.provider_options(target.provider) ~= nil
		and providers.load(target.provider, target.domain)
	if not target or not provider then
		done(picker_format.markdown(link_preview(link), width))
		return nil
	end

	if target.entity == "pr" and target.id and target.repo_full_name then
		---@cast provider PullsProvider
		local core = provider.capabilities.core
		---@type PullRequestRef
		local ref = { id = target.id, repo_full_name = target.repo_full_name }

		return core.fetch_by_refs({ ref }, { force_refresh = false }, function(pulls, err)
			local pr = pulls and pulls[1]
			if not pr then
				done(picker_format.markdown(link_preview(link, err or "Pull request not found"), width))
				return
			end

			done(picker_format.pullrequest(pr, nil, width))
		end)
	end

	---@cast provider IssuesProvider
	local ref = target.entity == "issue" and provider.issue_ref(target) or nil
	if not ref then
		done(picker_format.markdown(link_preview(link), width))
		return nil
	end

	local core = provider.capabilities.core
	return core.fetch_by_refs({ ref }, { force_refresh = false }, function(issues, err)
		local issue = issues and issues[1]
		if not issue then
			done(picker_format.markdown(link_preview(link, err or "Issue not found"), width))
			return
		end

		done(picker_format.issue(issue, nil, width, {
			provider = provider.id,
			fields = { { "Repository", target.repo_full_name } },
		}))
	end)
end

---@param links AtlasLink[]
---@param back fun()|nil
local function pick(links, back)
	if #links == 0 then
		notify.info("No links found")
		return
	end

	local previews = {}

	require("atlas.ui.picker").select_with_preview({
		title = "Links",
		items = links,
		key = function(link)
			return link.url
		end,
		format_item = function(link)
			local title = link.title ~= "" and link.title or link.key or link.url
			local text = icons.get("link") .. " " .. title:gsub("%c", " ")
			local relationship = link.relationship or ""
			if relationship == "" then
				return text
			end

			local highlight = relationship_highlights[vim.trim(relationship):lower()] or "AtlasTextMuted"
			return relationship .. " " .. text, { { relationship, highlight }, { " " .. text } }
		end,
		preview_item = function(link, done, width)
			if previews[link.url] then
				done(previews[link.url])
				return nil
			end

			return preview(link, function(result)
				previews[link.url] = result
				done(result)
			end, width)
		end,
		on_select = function(link)
			if not link then
				return
			end

			local target = providers.resolve(link.url)
			if target and config.provider_options(target.provider) then
				open.open(link.url, { back = back })
			else
				vim.ui.open(link.url)
			end
		end,
	})
end

---@param provider PullsProvider|IssuesProvider
---@param entity PullRequest|Issue
---@param kind "pr"|"issue"
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(links: AtlasLink[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(provider, entity, kind, opts, on_done)
	local fetch_links = provider.shared.fetch_links
	if not fetch_links then
		on_done({}, nil)
		return nil
	end

	return fetch_links(kind, entity, opts, on_done)
end

---@param provider PullsProvider|IssuesProvider
---@param entity PullRequest|Issue
---@param kind "pr"|"issue"
---@param items AtlasLink[]|nil Items already loaded, or nil to fetch them.
---@param back fun()|nil Reopens the panel the link was opened from, when going back.
function M.select(provider, entity, kind, items, back)
	if items then
		pick(items, back)
		return
	end

	fetch_requests.cancel()
	fetch_requests = request_scope.new()
	notify.loading("Loading links...")

	fetch_requests.run(function(done)
		return M.fetch(provider, entity, kind, nil, done)
	end, function(fetched, err)
		notify.clear()
		if err then
			notify.error("Links unavailable: " .. err)
			return
		end

		pick(fetched or {}, back)
	end)
end

return M
