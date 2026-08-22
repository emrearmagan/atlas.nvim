require("atlas.providers.gitea.config")

---@class AtlasGiteaIssuesSearchConfig
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
---@field created_by string|nil Gitea-only creator filter for cross-repository views.

---@class AtlasGiteaIssuesViewConfig : AtlasIssuesViewConfig, AtlasGiteaIssuesSearchConfig

---@class AtlasGiteaIssuesBookmarksConfig
---@field key string|nil
---@field label string|nil
---@field items table<string, AtlasGiteaIssuesSearchConfig>|nil

---@class AtlasGiteaIssuesConfig
---@field views AtlasGiteaIssuesViewConfig[]|nil
---@field bookmarks AtlasGiteaIssuesBookmarksConfig|nil
