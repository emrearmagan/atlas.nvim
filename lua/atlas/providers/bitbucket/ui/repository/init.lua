local overview = require("atlas.ui.repository.pages.overview")
local pulls = require("atlas.ui.repository.pages.pulls")
local builds = require("atlas.ui.repository.pages.builds")
local branches = require("atlas.ui.repository.pages.branches")
local tags = require("atlas.ui.repository.pages.tags")

return {
	pages = { overview, pulls, builds, branches, tags },
}
