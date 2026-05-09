---@class CreatePRLayout
---@field container_buf integer|nil
---@field container_win integer|nil
---@field title_buf integer|nil
---@field title_win integer|nil
---@field meta_buf integer|nil
---@field meta_win integer|nil
---@field desc_buf integer|nil
---@field desc_win integer|nil

---@class CreatePRFields
---@field repo_slug string         -- "owner/repo"
---@field repo_root string         -- absolute path to local repo
---@field provider PullsProvider
---@field head string              -- source branch
---@field base string              -- destination branch
---@field title string
---@field body string
---@field draft boolean
---@field available_bases string[]

---@class CreatePRState
---@field fields CreatePRFields
---@field layout CreatePRLayout
---@field content_width integer
---@field is_submitting boolean

local M = {
	fields = {
		repo_slug = "",
		repo_root = "",
		provider = nil,
		head = "",
		base = "",
		title = "",
		body = "",
		draft = false,
		available_bases = {},
	},
	layout = {},
	content_width = 80,
	is_submitting = false,
}

function M.reset()
	M.fields = {
		repo_slug = "",
		repo_root = "",
		provider = nil,
		head = "",
		base = "",
		title = "",
		body = "",
		draft = false,
		available_bases = {},
	}
	M.layout = {}
	M.content_width = 80
	M.is_submitting = false
end

return M
