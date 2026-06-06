local M = {}

local config = require("atlas.config")

---@return AtlasJiraIssuesConfig
function M.jira_config()
	local opts = config.options
	local issues = opts and opts.issues or nil
	local jira_config = (issues and issues.providers and issues.providers.jira) or {}

	jira_config.auth_method = jira_config.auth_method or "basic"
	jira_config.api_type = jira_config.api_type or "cloud"

	return jira_config
end

return M
