---@class BitbucketState
---@field buf integer|nil
---@field win integer|nil
---@field dim_win integer|nil
---@field ns integer
---@field prs table[]
---@field tree table[]
---@field line_map table<number, table>
---@field cache table
---@field current_view string|nil
---@field all_prs table[]

---@type BitbucketState
local state = {
  buf = nil,
  win = nil,
  dim_win = nil,
  ns = vim.api.nvim_create_namespace("Bitbucket"),
  prs = {},
  tree = {},
  line_map = {},
  cache = {},
  current_view = nil,
  all_prs = {},
}

return state
