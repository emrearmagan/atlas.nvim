local M = {}

local cli = require("atlas.pulls.providers.github.api.cli")
local diff_parser = require("atlas.core.git.diff_parser")

local function nilify(value)
	if value == nil or value == vim.NIL then
		return nil
	end
	return value
end

---@param raw table
---@return PullsComment
function M.normalize_review_comment(raw)
	local user = raw.user or {}
	local side = raw.side == "LEFT" and "old" or "new"
	local line = nilify(raw.line)
	local is_outdated = line == nil
	return {
		id = raw.id,
		parent_id = raw.in_reply_to_id,
		author = {
			name = tostring(user.login or ""),
			nickname = tostring(user.login or ""),
			id = tostring(user.id or ""),
		},
		content_raw = tostring(raw.body or ""),
		created_on = tostring(raw.created_at or ""),
		deleted = false,
		inline = {
			path = tostring(raw.path or ""),
			to = side == "new" and line or nil,
			from = side == "old" and line or nil,
			outdated = is_outdated,
		},
		url = nil,
		html_url = tostring(raw.html_url or ""),
	}
end

---Parse a GitHub `diff_hunk` string (the value GitHub puts on each review comment)
---into a single DiffHunk.
---@param diff_hunk string|nil
---@return DiffHunk|nil
local function parse_diff_hunk(diff_hunk)
	if type(diff_hunk) ~= "string" or diff_hunk == "" then
		return nil
	end
	-- Wrap the raw diff_hunk in a synthetic file diff so the existing parser accepts it.
	local synthetic = "diff --git a/x b/x\n--- a/x\n+++ b/x\n" .. diff_hunk .. "\n"
	local files = diff_parser.parse(synthetic)
	if #files == 0 or #files[1].hunks == 0 then
		return nil
	end
	---@diagnostic disable-next-line: return-type-mismatch
	return files[1].hunks[1]
end

---@param raw_comments table
---@return PullsComment[]
local function normalize_review_comments(raw_comments)
	local list = {}
	for _, c in ipairs(raw_comments or {}) do
		table.insert(list, M.normalize_review_comment(c))
	end
	return list
end

---Build the PullsCommentThread list from a flat array of review comments,
---using in_reply_to_id (parent_id) for threading.
---@param comments PullsComment[]
---@return PullsCommentThread[]
local function thread_review_comments(comments)
	---@type table<string, PullsCommentThread>
	local by_id = {}
	for _, c in ipairs(comments) do
		by_id[tostring(c.id)] = { root = c, replies = {} }
	end

	local roots = {}
	for _, c in ipairs(comments) do
		local pid = c.parent_id
		if pid ~= nil and by_id[tostring(pid)] ~= nil then
			table.insert(by_id[tostring(pid)].replies, c)
		else
			table.insert(roots, by_id[tostring(c.id)])
		end
	end

	for _, node in pairs(by_id) do
		table.sort(node.replies, function(a, b)
			return tostring(a.created_on or "") < tostring(b.created_on or "")
		end)
	end

	return roots
end

---@param threads PullsCommentThread[]
---@param raw_by_id table<string, table>   review-comment raw payloads, keyed by id
---@return PullsFileThread[]
local function group_file_threads(threads, raw_by_id)
	---@type table<string, PullsFileThread>
	local by_key = {}
	---@type PullsFileThread[]
	local ordered = {}

	for _, t in ipairs(threads) do
		local root = t.root
		local inline = root.inline
		if inline ~= nil and not inline.outdated then
			local path = tostring(inline.path or "")
			local line = inline.to or inline.from
			local side = inline.to ~= nil and "new" or "old"
			local key = string.format("%s|%s|%s", path, side, tostring(line or ""))

			local entry = by_key[key]
			if entry == nil then
				local raw = raw_by_id[tostring(root.id)] or {}
				entry = {
					path = path,
					side = side,
					line = line,
					start_line = raw.start_line,
					hunk = parse_diff_hunk(raw.diff_hunk),
					threads = {},
				}
				by_key[key] = entry
				table.insert(ordered, entry)
			end
			table.insert(entry.threads, t)
		end
	end

	return ordered
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(snapshot: PullsConversationSnapshot|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_snapshot(pr, opts, on_done)
	opts = opts or {}
	local slug = tostring(pr.repo_full_name or "")
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	local handles = {}
	local cancelled = false

	local review_comments_raw = nil
	local first_err = nil

	local function finish_if_ready()
		if cancelled or review_comments_raw == nil then
			return
		end

		local review_comments = normalize_review_comments(review_comments_raw)
		local threads = thread_review_comments(review_comments)

		local raw_by_id = {}
		for _, raw in ipairs(review_comments_raw) do
			raw_by_id[tostring(raw.id)] = raw
		end

		local file_threads = group_file_threads(threads, raw_by_id)

		---@type PullsConversationSnapshot
		local snapshot = {
			general = {},
			file_threads = file_threads,
			tasks = nil,
		}
		on_done(snapshot, first_err)
	end

	local h2 = cli.gh({
		"api",
		"--paginate",
		string.format("repos/%s/pulls/%s/comments?per_page=100", slug, tostring(pr.id)),
	}, function(result, err)
		if err then
			first_err = first_err or err
			review_comments_raw = {}
		else
			review_comments_raw = type(result) == "table" and result or {}
		end
		finish_if_ready()
	end)
	if h2 then
		table.insert(handles, h2)
	end

	return {
		cancel = function()
			cancelled = true
			for _, h in ipairs(handles) do
				if h and h.cancel then
					pcall(h.cancel)
				end
			end
		end,
	}
end

return M
