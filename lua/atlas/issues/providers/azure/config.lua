-- WIQL syntax: https://learn.microsoft.com/en-us/azure/devops/boards/queries/wiql-syntax

---@class AtlasAzureIssuesViewConfig : IssuesViewConfig
---@field project string|nil Azure DevOps project name.
---@field current_repo boolean|nil Use the project of the current Git repository; alternative to project.
---@field search string Native flat WIQL query.

---@class AtlasAzureIssuesBookmarkConfig : AtlasIssuesBookmarkConfig
---@field project string
---@field search string

---@class AtlasAzureIssuesBookmarksConfig
---@field key string|nil
---@field label string|nil
---@field items table<string, AtlasAzureIssuesBookmarkConfig>|nil

---@class AtlasAzureIssuesConfig
---@field views AtlasAzureIssuesViewConfig[]|nil
---@field bookmarks AtlasAzureIssuesBookmarksConfig|nil
