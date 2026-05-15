local M = {}

local cli = require("atlas.issues.providers.github.api.cli")
local normalizer = require("atlas.issues.providers.github.api.mapper")
local json = require("atlas.core.json")

---@param key string
---@param on_done fun(result: { comments: IssueComment[], events: IssueActivityEntry[] }|nil, err: string|nil)
---@param opts { force_load?: boolean }|nil
---@return { cancel: fun() }|nil
function M.list_conversation(key, on_done, opts)
	opts = opts or {}
	local slug, number = normalizer.parse_key(key)
	if slug == "" or number == nil then
		on_done(nil, "Invalid issue key")
		return nil
	end

	local cache_key = string.format("github_issues:conversation:%s#%d", slug, number)
	if not opts.force_load then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh(
		{ "api", "--paginate", string.format("repos/%s/issues/%d/timeline", slug, number) },
		function(result, err)
			if err then
				on_done(nil, err)
				return
			end

			local conversation = { comments = {}, events = {} }
			for _, raw in ipairs(type(result) == "table" and result or {}) do
				local raw_event = type(raw) == "table" and json.safe_str(raw.event) or ""
				if raw_event == "commented" then
					local comment = normalizer.to_timeline_comment(raw)
					if comment then
						table.insert(conversation.comments, comment)
					end
				else
					local entry = normalizer.to_timeline_entry(raw)
					if entry then
						table.insert(conversation.events, entry)
					end
				end
			end

			cli.set_mem(cache_key, conversation)
			on_done(conversation, nil)
		end,
		{
			action = "Fetch issue conversation timeline",
			slug = slug,
			number = number,
		}
	)
end

return M
