local M = {}

local pullrequests = require("atlas.pulls.providers.bitbucket.api.server.pullrequests")

M.fetch_activity = pullrequests.fetch_activity

return M
