-- Example:
--   require("atlas").setup({
--     providers = {
--       ---@type AtlasJiraProviderConfig
--       jira = {
--         base_url = "https://your-domain.atlassian.net",
--         email    = vim.env.JIRA_EMAIL,
--         token    = vim.env.JIRA_TOKEN,
--         api_type = "cloud",
--         auth_method = "basic", -- "basic" | "bearer"
--         cache_ttl = 300,
--
--         -- Global Jira display settings and per-project custom fields
--         project_config = {
--           story_points_field = "customfield_10016",
--           issue_types = {
--             ["Maintenance"] = { icon = "", hl_group = "AtlasTextWarning" },
--             ["Infrastructure"] = { icon = "󰒋", hl_group = "AtlasLogInfo" },
--           },
--           KAN = {
--             customfield_10038 = {
--               name    = "Team",
--               format  = function(v) return type(v) == "table" and v.value or nil end,
--               hl_group = "AtlasChipActive",
--               display  = "chip", -- "chip" | "table"
--             },
--           },
--         },
--       },
--     },
--     issues = {
--       ---@type AtlasJiraIssuesConfig
--       jira = {
--         views = {
--           { name = "Open",       key = "1", jql = "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC" },
--           { name = "Reported",   key = "2", jql = "reporter = currentUser() AND resolution = Unresolved ORDER BY updated DESC" },
--           { name = "Watching",   key = "3", jql = "watcher = currentUser() AND resolution = Unresolved ORDER BY updated DESC" },
--           { name = "Sprint",     key = "4", jql = "sprint in openSprints() AND assignee = currentUser() ORDER BY rank" },
--         },
--         bookmarks = {
--           -- key   = "J",   -- default
--           -- label = "JQL", -- default
--           items = {
--             ["Backlog"]     = "project = KAN AND statusCategory != Done AND (sprint IS EMPTY OR sprint NOT IN openSprints()) ORDER BY Rank ASC",
--             ["Next sprint"] = "project = KAN AND sprint in futureSprints() ORDER BY Rank ASC",
--           },
--         },
--       },
--     },
--   })

---@class AtlasJiraViewConfig : IssuesViewConfig
---@field jql string

---@class AtlasJiraCustomFieldConfig
---@field name string
---@field format fun(value: any): string|nil
---@field hl_group string|nil
---@field display "chip"|"table"|nil

---@class AtlasJiraIssueTypeConfig
---@field icon string|nil
---@field hl_group string|nil

---@alias AtlasJiraIssueTypesConfig table<string, AtlasJiraIssueTypeConfig>

---@alias AtlasJiraProjectFieldsConfig table<string, AtlasJiraCustomFieldConfig>

---@class AtlasJiraProjectConfig
---@field story_points_field string|nil
---@field issue_types AtlasJiraIssueTypesConfig|nil
---@field [string] AtlasJiraProjectFieldsConfig

---@class AtlasJiraBookmarksConfig
---@field key string|nil    -- default "J"
---@field label string|nil  -- default "JQL"
---@field items table<string, string>|nil

---@class AtlasJiraProviderConfig
---@field base_url string
---@field email string
---@field token string
---@field api_type string|nil
---@field auth_method "basic"|"bearer"|nil
---@field cache_ttl number|nil
---@field project_config AtlasJiraProjectConfig|nil

---@class AtlasJiraIssuesConfig
---@field views AtlasJiraViewConfig[]|nil
---@field bookmarks AtlasJiraBookmarksConfig|nil

---@class AtlasJiraConfig : AtlasJiraProviderConfig, AtlasJiraIssuesConfig
