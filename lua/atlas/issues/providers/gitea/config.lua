require("atlas.providers.gitea.config")

---@class AtlasGiteaForgejoIssuesSearchConfig
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
---@field current_repo boolean|nil

---@class AtlasGiteaIssuesSearchConfig : AtlasGiteaForgejoIssuesSearchConfig
---@field created_by string|nil Gitea-only creator filter for cross-repository views.

---@class AtlasForgejoIssuesSearchConfig : AtlasGiteaForgejoIssuesSearchConfig
---@field sort "relevance"|"latest"|"oldest"|"recentupdate"|"leastupdate"|"mostcomment"|"leastcomment"|"nearduedate"|"farduedate"|nil Forgejo only.
---@field priority_repo_id integer|nil Forgejo-only repository to prioritize in cross-repository results.

---@class AtlasGiteaIssuesViewConfig : AtlasIssuesViewConfig, AtlasGiteaIssuesSearchConfig

---@class AtlasForgejoIssuesViewConfig : AtlasIssuesViewConfig, AtlasForgejoIssuesSearchConfig

---@alias AtlasGiteaForgejoIssuesViewConfig AtlasGiteaIssuesViewConfig|AtlasForgejoIssuesViewConfig

---@class AtlasGiteaIssuesBookmarksConfig
---@field key string|nil
---@field label string|nil
---@field items table<string, AtlasGiteaIssuesSearchConfig>|nil

---@class AtlasForgejoIssuesBookmarksConfig
---@field key string|nil
---@field label string|nil
---@field items table<string, AtlasForgejoIssuesSearchConfig>|nil

---@class AtlasGiteaIssuesConfig : AtlasGiteaForgejoConfig
---@field api_type "gitea"|nil Defaults to Gitea.
---@field views AtlasGiteaIssuesViewConfig[]|nil
---@field bookmarks AtlasGiteaIssuesBookmarksConfig|nil

---@class AtlasForgejoIssuesConfig : AtlasGiteaForgejoConfig
---@field api_type "forgejo"
---@field views AtlasForgejoIssuesViewConfig[]|nil
---@field bookmarks AtlasForgejoIssuesBookmarksConfig|nil

---@alias AtlasGiteaForgejoIssuesConfig AtlasGiteaIssuesConfig|AtlasForgejoIssuesConfig
