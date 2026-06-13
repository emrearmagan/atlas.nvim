-- Example configuration:
--   require("atlas").setup({
--     pulls = {
--       providers = {
--         gitea = {
--           cache_ttl = 300,
--           views = {
--             { name = "Open",   key = "1", filter = { state = "open" },   repo = "owner/repo" },
--             { name = "Merged", key = "2", filter = { state = "merged" }, repo = "owner/repo" },
--             { name = "Closed", key = "3", filter = { state = "closed" }, repo = "owner/repo" },
--           },
--         },
--       },
--     },
--   })

---@class AtlasGiteaPullsFilter
---@field state "open"|"closed"|"merged"|"declined"|nil

---@class AtlasGiteaPullsViewConfig : AtlasPullsViewConfig
---@field filter AtlasGiteaPullsFilter|nil
---@field repo string|nil  "owner/repo" slug; if omitted, auto-detected from git remote

---@class AtlasGiteaConfig
---@field cache_ttl number|nil
---@field views AtlasGiteaPullsViewConfig[]|nil
