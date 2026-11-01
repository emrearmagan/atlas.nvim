local overview = require("atlas.ui.repository.pages.overview")
local issues = require("atlas.ui.repository.pages.issues")
local pulls = require("atlas.ui.repository.pages.pulls")
local branches = require("atlas.ui.repository.pages.branches")
local tags = require("atlas.ui.repository.pages.tags")

return {
	pages = { overview, issues, pulls, branches, tags },
}
