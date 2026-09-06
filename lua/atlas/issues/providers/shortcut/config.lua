-- Example:
--   require("atlas").setup({
--     providers = {
--       ---@type AtlasShortcutConfig
--       shortcut = {
--         token = vim.env.SHORTCUT_TOKEN,
--         cache_ttl = 300,
--       },
--     },
--     issues = {
--       ---@type AtlasShortcutIssuesConfig
--       shortcut = {
--         views = {
--           { name = "Mine", key = "1", search = "owner:johnsmith !is:done" },
--           { name = "Bugs", key = "2", search = "type:bug !is:done" },
--         },
--         bookmarks = {
--           -- key   = "S",      -- default
--           -- label = "Search", -- default
--           items = {
--             ["Open bugs"] = "type:bug !is:done !is:archived",
--             ["Needs review"] = { search = 'label:"needs-review" !is:done', layout = "plain" },
--           },
--         },
--       },
--     },
--   })

---@class AtlasShortcutConfig
---@field token string
---@field cache_ttl number|nil Cache lifetime in seconds (default: 300); values <= 0 disable caching.

---@class AtlasShortcutIssuesViewConfig : IssuesViewConfig
---@field search string

---@class AtlasShortcutIssuesBookmarkConfig : AtlasIssuesBookmarkConfig
---@field search string

---@class AtlasShortcutIssuesBookmarksConfig
---@field key string|nil    -- default "S"
---@field label string|nil  -- default "Search"
---@field items table<string, string|AtlasShortcutIssuesBookmarkConfig>|nil

---@class AtlasShortcutIssuesConfig
---@field views AtlasShortcutIssuesViewConfig[]|nil
---@field bookmarks AtlasShortcutIssuesBookmarksConfig|nil
