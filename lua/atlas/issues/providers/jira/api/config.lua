local M = {}

local config = require("atlas.config")

---@return AtlasJiraIssuesConfig
function M.jira_config()
	local opts = config.options
	local issues = opts and opts.issues or nil
	local jira_config = (issues and issues.providers and issues.providers.jira) or {}

	jira_config.api_version = tostring(jira_config.api_version or "3")

	return jira_config
end

return M
