-- WIQL syntax: https://learn.microsoft.com/en-us/azure/devops/boards/queries/wiql-syntax

local M = {}

local prompt = require("atlas.ui.prompt")

local PULL_QUALIFIERS = { "is", "project", "repository", "scope" }
local PULL_VALUES = {
	is = { "open", "merged", "declined" },
	scope = { "all", "assigned_to_me", "created_by_me" },
}

local WIQL_WORDS = {
	"SELECT",
	"FROM",
	"WorkItems",
	"WHERE",
	"AND",
	"OR",
	"NOT",
	"IN",
	"CONTAINS",
	"UNDER",
	"EVER",
	"ORDER",
	"BY",
	"ASC",
	"DESC",
	"[System.Id]",
	"[System.Title]",
	"[System.State]",
	"[System.WorkItemType]",
	"[System.AssignedTo]",
	"[System.CreatedBy]",
	"[System.TeamProject]",
	"[System.AreaPath]",
	"[System.IterationPath]",
	"[System.Tags]",
	"[System.CreatedDate]",
	"[System.ChangedDate]",
	"[Microsoft.VSTS.Common.Priority]",
	"[Microsoft.VSTS.Common.ClosedDate]",
	"@Me",
	"@project",
	"@Today",
	"@CurrentIteration",
}

---@param arglead string
---@return string[]
local function complete_pulls(arglead)
	local key = arglead:match("^([%w_]+):")
	local items = {}
	if PULL_VALUES[key] then
		for _, value in ipairs(PULL_VALUES[key]) do
			table.insert(items, key .. ":" .. value)
		end
	else
		for _, qualifier in ipairs(PULL_QUALIFIERS) do
			table.insert(items, qualifier .. ":")
		end
	end

	return vim.tbl_filter(function(item)
		return item:sub(1, #arglead) == arglead
	end, items)
end

---@param arglead string
---@return string[]
local function complete_wiql(arglead)
	local lead = arglead:lower()
	return vim.tbl_filter(function(item)
		return item:lower():sub(1, #lead) == lead
	end, WIQL_WORDS)
end

---@param kind "pulls"|"wiql"
---@param default string
---@param on_submit fun(query: string)
function M.edit(kind, default, on_submit)
	default = vim.trim(default:gsub("%s+", " "))
	prompt.open({
		name = "AtlasAzureSearch",
		prompt = kind == "pulls" and "Azure search: " or "WIQL: ",
		default = default ~= "" and default .. " " or "",
		complete = kind == "pulls" and complete_pulls or complete_wiql,
		on_submit = function(query)
			query = vim.trim(query)
			if query ~= "" then
				on_submit(query)
			end
		end,
	})
end

return M
