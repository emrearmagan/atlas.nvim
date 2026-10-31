local M = {}

local prompt = require("atlas.ui.prompt")

---@param kind "pulls"|"issues"
---@param default string
---@param on_submit fun(query: string)
function M.edit(kind, default, on_submit)
	local qualifiers = kind == "pulls"
			and {
				"is",
				"project",
				"group",
				"scope",
				"labels",
				"milestone",
				"author",
				"assignee",
				"review_states",
				"source_branch",
				"target_branch",
				"sort",
				"order_by",
				"search",
			}
		or { "is", "project", "scope", "labels", "milestone", "author", "assignee", "sort", "order_by", "search" }
	local states = kind == "pulls" and { "open", "merged", "declined" } or { "opened", "closed", "all" }

	default = vim.trim(default)
	prompt.open({
		name = "AtlasGitLabSearch",
		prompt = "GitLab search: ",
		default = default ~= "" and default .. " " or "",
		complete = function(arglead)
			local is_state = arglead:match("^is:") ~= nil
			local items = {}
			for _, item in ipairs(is_state and states or qualifiers) do
				table.insert(items, is_state and ("is:" .. item) or (item .. ":"))
			end

			return vim.tbl_filter(function(item)
				return item:sub(1, #arglead) == arglead
			end, items)
		end,
		on_submit = function(query)
			query = vim.trim(query)
			if query ~= "" then
				on_submit(query)
			end
		end,
	})
end

return M
