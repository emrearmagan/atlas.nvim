require("atlas.providers.forgejo.config")

---@class AtlasForgejoIssuesSearchConfig
---@field repo string|nil Repository-scoped view. Omit to search across repositories.
---@field state "open"|"closed"|"all"|nil
---@field scope "assigned"|"created"|"mentioned"|"all"|nil
---@field search string|nil
---@field labels string|nil
---@field milestones string|nil
---@field since string|nil RFC 3339 timestamp.
---@field before string|nil RFC 3339 timestamp.
---@field owner string|nil Owner filter for cross-repository views.
---@field team string|nil Team filter for cross-repository views.
---@field sort "relevance"|"latest"|"oldest"|"recentupdate"|"leastupdate"|"mostcomment"|"leastcomment"|"nearduedate"|"farduedate"|nil
---@field priority_repo_id integer|nil Repository to prioritize in cross-repository results.

---@class AtlasForgejoIssuesViewConfig : AtlasIssuesViewConfig, AtlasForgejoIssuesSearchConfig

---@class AtlasForgejoIssuesBookmarksConfig
---@field key string|nil
---@field label string|nil
---@field items table<string, AtlasForgejoIssuesSearchConfig>|nil

---@class AtlasForgejoIssuesConfig
---@field views AtlasForgejoIssuesViewConfig[]|nil
---@field bookmarks AtlasForgejoIssuesBookmarksConfig|nil
