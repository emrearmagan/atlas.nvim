local M = {}

local config = require("atlas.config")
local notify = require("atlas.core.notify")
local picker_format = require("atlas.ui.picker.format")
local providers = require("atlas.providers")
local request_scope = require("atlas.core.requests")
local icons = require("atlas.ui.shared.icons")

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

local function clean(value)
	return tostring(value or ""):gsub("[%c]", " ")
end

---@param provider PullsProvider|IssuesProvider
---@param entity PullRequest|Issue
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(links: AtlasRelatedItem[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(provider, entity, opts, on_done)
	local fetch_links = provider.capabilities.core.fetch_links
	if not fetch_links then
		on_done({}, nil)
		return nil
	end
	return fetch_links(entity, opts, on_done)
end

---@param links AtlasRelatedItem[]
---@param pr PullRequest|nil
---@return AtlasRelatedItem[]
function M.items(links, pr)
	local result, seen = {}, {}
	local source = vim.list_extend({}, links)
	if pr then
		local jira = require("atlas.providers.jira.links")
		vim.list_extend(source, jira.resolve(pr.title, pr.source and pr.source.branch))
	end
	for _, link in ipairs(source) do
		if link.url and link.url ~= "" and not seen[link.url] then
			seen[link.url] = true
			table.insert(result, link)
		end
	end
	return result
end

---@param link AtlasRelatedItem
---@return string
---@return AtlasPickerChunk[]|nil
local function link_label(link)
	local icon
	if link.kind == "pr" then
		icon = icons.get("pr")
	elseif link.kind == "issue" then
		icon = icons.get("issue")
	else
		icon = icons.get("open_in_browser", "actions")
	end
	local relationship = clean(link.relationship)
	local title = clean(link.title)
	if title == "" then
		title = clean(link.key or link.url)
	end
	local text = icon .. (title ~= "" and " " .. title or "")
	if relationship == "" then
		return text
	end
	return relationship .. " " .. text,
		{
			{ relationship, relationship_highlights[vim.trim(relationship):lower()] or "AtlasTextMuted" },
			{ " " .. text },
		}
end

---@param link AtlasRelatedItem
---@return AtlasTarget|nil, PullsProvider|IssuesProvider|nil, PullRequestRef|IssueRef|nil
local function resolve(link)
	local target = link.kind ~= "external" and providers.resolve(link.url) or nil
	local provider = target
		and config.provider_options(target.provider) ~= nil
		and providers.load(target.provider, target.domain)
	if not target or not provider then
		return nil
	end
	if target.entity == "pr" and target.id and target.repo_full_name then
		return target, provider, { id = target.id, repo_full_name = target.repo_full_name }
	end
	if target.entity == "issue" then
		---@cast provider IssuesProvider
		local ref = provider.issue_ref(target)
		if ref then
			return target, provider, ref
		end
	end
	return nil
end

---@param link AtlasRelatedItem
---@param back fun()|nil
local function open(link, back)
	local target, provider, ref = resolve(link)
	if not target then
		if link.url:match("^https?://") then
			vim.ui.open(link.url)
		end
	elseif target.entity == "pr" then
		---@cast provider PullsProvider
		---@cast ref PullRequestRef
		require("atlas.pulls.ui.detail").open(ref, { provider = provider, back = back })
	else
		---@cast provider IssuesProvider
		---@cast ref IssueRef
		require("atlas.issues.ui.detail").open_ref(ref, { provider = provider, back = back })
	end
end

---@param lines string[]
---@param label string
---@param value string|number|nil
local function field(lines, label, value)
	local text = vim.trim(clean(value))
	if text ~= "" then
		table.insert(lines, "**" .. label .. ":** " .. text)
	end
end

---@param link AtlasRelatedItem
---@param err string|nil
---@return AtlasPickerPreview
local function link_preview(link, err)
	local title = clean(link.title or link.key or link.url)
	local lines = { "# " .. title, "" }
	field(lines, "Relationship", link.relationship)
	field(lines, "URL", link.url)
	if err then
		vim.list_extend(lines, { "", "> Could not load: " .. clean(err) })
	end
	return { title = link.key or title, lines = lines }
end

---@param link AtlasRelatedItem
---@param width integer
---@param done fun(preview: AtlasPickerPreview)
---@return { cancel: fun() }|nil
local function load_preview(link, width, done)
	local target, provider, ref = resolve(link)
	if not target then
		done(picker_format.markdown(link_preview(link), width))
		return nil
	end

	local relationship = { "Relationship", link.relationship }

	local requests = request_scope.new()
	if target.entity == "pr" then
		---@cast provider PullsProvider
		---@cast ref PullRequestRef
		local core = provider.capabilities.core
		requests.all({
			pr = function(callback)
				return core.fetch_by_refs({ ref }, { force_refresh = false }, callback)
			end,
			details = function(callback)
				return core.fetch_pullrequest(ref, { force_refresh = false }, callback)
			end,
		}, function(values, errors)
			local pr = values.pr and values.pr[1]
			done(
				pr and picker_format.pullrequest(pr, values.details, width, { fields = { relationship } })
					or picker_format.markdown(link_preview(link, errors.pr or "Pull request not found"), width)
			)
		end)
		return requests
	end

	---@cast provider IssuesProvider
	---@cast ref IssueRef
	local core = provider.capabilities.core
	requests.all({
		issue = function(callback)
			return core.fetch_by_refs({ ref }, { force_refresh = false }, callback)
		end,
		details = function(callback)
			return core.fetch_issue(ref, { force_refresh = false }, callback)
		end,
	}, function(values, errors)
		local issue = values.issue and values.issue[1]
		done(issue and picker_format.issue(issue, values.details, width, {
			provider = provider.id,
			fields = { { "Repository", target.repo_full_name or target.project_path }, relationship },
		}) or picker_format.markdown(link_preview(link, errors.issue or "Issue not found"), width))
	end)
	return requests
end

---Previews are cached for as long as the picker is open.
---@return AtlasPickerPreviewItem
local function new_preview()
	local cache = {}
	return function(link, done, width)
		if cache[link.url] then
			done(cache[link.url])
			return nil
		end
		return load_preview(link, width, function(preview)
			cache[link.url] = preview
			done(preview)
		end)
	end
end

---@param links AtlasRelatedItem[]
---@param empty string
---@param back fun()|nil
local function pick(links, empty, back)
	if #links == 0 then
		notify.info(empty)
		return
	end
	require("atlas.ui.picker").select_with_preview({
		title = "Links",
		items = links,
		key = function(link)
			return link.url
		end,
		format_item = link_label,
		preview_item = new_preview(),
		on_select = function(link)
			if link then
				open(link, back)
			end
		end,
	})
end

local fetch_requests = request_scope.new()

---@param provider PullsProvider|IssuesProvider
---@param entity PullRequest|Issue
---@param kind "pr"|"issue"
---@param links AtlasRelatedItem[]|nil Links already loaded, or nil to fetch them.
---@param back fun()|nil Reopens the panel the link was opened from, when going back.
function M.select(provider, entity, kind, links, back)
	local pr = kind == "pr" and entity --[[@as PullRequest]] or nil
	if links then
		pick(M.items(links, pr), "No matching links", back)
		return
	end
	fetch_requests.cancel()
	fetch_requests = request_scope.new()
	notify.loading("Loading links...")
	fetch_requests.run(function(done)
		return M.fetch(provider, entity, nil, done)
	end, function(fetched, err)
		notify.clear()
		pick(M.items(fetched or {}, pr), err and ("Links unavailable: " .. err) or "No matching links", back)
	end)
end

return M
