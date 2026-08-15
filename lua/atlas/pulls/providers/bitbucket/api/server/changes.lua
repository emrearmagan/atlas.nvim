local M = {}

local pullrequests = require("atlas.pulls.providers.bitbucket.api.server.pullrequests")

M.fetch_diffstat = pullrequests.fetch_diffstat
M.fetch_commits = pullrequests.fetch_commits
M.fetch_diff = pullrequests.fetch_diff

return M
