local overview = require("atlas.ui.repository.pages.overview")
local pulls = require("atlas.ui.repository.pages.pulls")
local builds = require("atlas.ui.repository.pages.builds")
local branches = require("atlas.ui.repository.pages.branches")
local tags = require("atlas.ui.repository.pages.tags")
local deployments = require("atlas.providers.bitbucket.ui.repository.pages.deployments")

return {
	pages = { overview, pulls, builds, branches, tags, deployments },
}
