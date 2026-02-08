---@class UnifiedPlugin
local M = {}

local config = require("atlas.common.config")
local bitbucket_command = require("atlas.command")

---@param cmd_line string
local function bitbucket_complete(_, cmd_line, _)
  local args = vim.split(cmd_line, "%s+", { trimempty = true })
  if #args <= 1 then
    return bitbucket_command.SUBCOMMANDS
  end
  return {}
end

---@param cmd_line string
local function jira_complete(_, cmd_line, _)
  local args = vim.split(cmd_line, "%s+", { trimempty = true })
  if #args <= 1 then
    local jira_command = require("atlas.jira-command")
    return jira_command.SUBCOMMANDS
  end
  return {}
end

---@param opts UnifiedConfig
function M.setup(opts)
  config.setup(opts)

  -- Bitbucket command
  vim.api.nvim_create_user_command("Bitbucket", function(ctx)
    bitbucket_command.execute(ctx.args)
  end, {
    nargs = "*",
    bang = true,
    complete = bitbucket_complete,
    desc = "Bitbucket PR viewer: :Bitbucket [prs|help]",
  })

  -- Jira command
  vim.api.nvim_create_user_command("Jira", function(ctx)
    local jira_command = require("atlas.jira-command")
    jira_command.execute(ctx.args)
  end, {
    nargs = "*",
    bang = true,
    complete = jira_complete,
    desc = "Jira view: :Jira [<PROJECT_KEY>] | info <ISSUE_KEY> | create [<PROJECT_KEY>]",
  })
end

return M
