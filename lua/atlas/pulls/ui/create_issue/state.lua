---@class CreateIssueLayout
---@field container_buf integer|nil
---@field container_win integer|nil
---@field title_buf integer|nil
---@field title_win integer|nil
---@field meta_buf integer|nil
---@field meta_win integer|nil
---@field desc_buf integer|nil
---@field desc_win integer|nil

---@class CreateIssueLabel
---@field name string
---@field color string|nil

---@class CreateIssueAssignee
---@field login string
---@field name string|nil

---@class CreateIssueMilestone
---@field number integer
---@field title string

---@class CreateIssuePickers
---@field list_labels fun(on_done: fun(items: CreateIssueLabel[]|nil, err: string|nil))|nil
---@field list_assignees fun(on_done: fun(items: CreateIssueAssignee[]|nil, err: string|nil))|nil
---@field list_milestones fun(on_done: fun(items: CreateIssueMilestone[]|nil, err: string|nil))|nil

---@class CreateIssueSubmitOpts
---@field repo_slug string
---@field title string
---@field body string
---@field labels string[]
---@field assignees string[]
---@field milestone integer|nil

---@class CreateIssueFields
---@field repo_slug string
---@field title string
---@field body string
---@field labels CreateIssueLabel[]
---@field assignees CreateIssueAssignee[]
---@field milestone CreateIssueMilestone|nil

---@class CreateIssueState
---@field fields CreateIssueFields
---@field layout CreateIssueLayout
---@field content_width integer
---@field is_submitting boolean
---@field pickers CreateIssuePickers
---@field on_submit fun(opts: CreateIssueSubmitOpts, on_done: fun(result: { url: string|nil, number: integer|nil }|nil, err: string|nil))|nil

local M = {
	fields = {
		repo_slug = "",
		title = "",
		body = "",
		labels = {},
		assignees = {},
		milestone = nil,
	},
	layout = {},
	content_width = 80,
	is_submitting = false,
	pickers = {},
	on_submit = nil,
}

function M.reset()
	M.fields = {
		repo_slug = "",
		title = "",
		body = "",
		labels = {},
		assignees = {},
		milestone = nil,
	}
	M.layout = {}
	M.content_width = 80
	M.is_submitting = false
	M.pickers = {}
	M.on_submit = nil
end

return M
