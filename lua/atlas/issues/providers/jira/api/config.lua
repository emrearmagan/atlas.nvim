local M = {}

local config = require("atlas.config")

---@return AtlasJiraIssuesConfig
function M.jira_config()
	local opts = config.options
	local issues = opts and opts.issues or nil
	return (issues and issues.providers and issues.providers.jira) or {}
end

return M
