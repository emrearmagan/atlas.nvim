local overview = require("atlas.ui.repository.pages.overview")
local branches = require("atlas.ui.repository.pages.branches")
local tags = require("atlas.ui.repository.pages.tags")

return {
	pages = { overview, branches, tags },
}
