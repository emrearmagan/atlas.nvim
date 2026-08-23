local M = {}

local config = require("atlas.config")

---@return AtlasJiraConfig
function M.jira_config()
	local jira_config = vim.tbl_extend("force", {}, config.provider_options("jira") or {})
	local issues_config = config.domain_options("jira", "issues") or {}
	jira_config.views = issues_config.views
	jira_config.bookmarks = issues_config.bookmarks
	---@cast jira_config AtlasJiraConfig

	jira_config.auth_method = jira_config.auth_method or "basic"
	jira_config.api_type = jira_config.api_type or "cloud"

	return jira_config
end

return M
