---@class Bitbucket.Command
local M = {}

---@type string[]
M.SUBCOMMANDS = { "prs", "help" }

---@param args string
function M.execute(args)
  local parts = {}
  for part in args:gmatch("%S+") do
    table.insert(parts, part)
  end

  local cmd = parts[1]

  if cmd == "help" or cmd == "?" then
    require("atlas.bitbucket-board").toggle_help()
    return
  end

  require("atlas.bitbucket-board").open()
end

return M
