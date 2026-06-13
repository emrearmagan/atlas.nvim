-- Example configuration:
--   require("atlas").setup({
--     issues = {
--       providers = {
--         gitea = {
--           cache_ttl = 300,
--           views = {
--             { name = "Assigned", key = "1", filter = { assigned = true, state = "open" } },
--             { name = "Created",  key = "2", filter = { created  = true, state = "open" } },
--             { name = "All Open", key = "3", repo = "owner/repo", filter = { state = "open" } },
--           },
--         },
--       },
--     },
--   })

---@class AtlasGiteaIssuesFilter
---@field state "open"|"closed"|nil
---@field assigned boolean|nil
---@field created boolean|nil
---@field mentioned boolean|nil

---@class AtlasGiteaIssuesViewConfig : AtlasIssuesViewConfig
---@field filter AtlasGiteaIssuesFilter|nil
---@field repo string|nil  "owner/repo" for repo-scoped views

---@class AtlasGiteaIssuesConfig
---@field cache_ttl number|nil
---@field views AtlasGiteaIssuesViewConfig[]|nil
