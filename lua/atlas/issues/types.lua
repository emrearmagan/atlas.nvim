--------------------------------------------------------------------------------
-- User
--------------------------------------------------------------------------------

---@class IssueUser
---@field id integer|nil
---@field account_id string|nil
---@field display_name string

--------------------------------------------------------------------------------
-- Issue
--------------------------------------------------------------------------------

---@class IssueRef
---@field key string
---@field title string|nil

---@class Issue : IssueRef
---@field title string
---@field status string|nil
---@field status_id string|nil
---@field type IssueType|nil
---@field assignee IssueUser|nil
---@field reporter IssueUser|nil
---@field story_points number|nil
---@field duedate string|nil
---@field parent IssueRef|nil
---@field url string|nil
---@field created_at string|nil
---@field updated_at string|nil
---@field closed_at string|nil
---@field comment_count integer|nil
---@field is_starred boolean|nil
---@field is_subscribed boolean|nil

---@class IssueDetails : Issue
---@field description string
---@field assignees IssueUser[]
---@field labels IssueLabel[]
---@field milestone IssueMilestone|nil
---@field reactions table<string, integer>|nil
---@field sub_issues Issue[]
---@field _raw table|nil

--------------------------------------------------------------------------------
-- Label
--------------------------------------------------------------------------------

---@class IssueLabel
---@field name string
---@field color string|nil

--------------------------------------------------------------------------------
-- Milestone
--------------------------------------------------------------------------------

---@class IssueMilestone
---@field title string
---@field progress_percentage number|nil
---@field open_issues integer|nil
---@field closed_issues integer|nil

--------------------------------------------------------------------------------
-- Group
--------------------------------------------------------------------------------

---@class IssuesGroup
---@field issue Issue
---@field children Issue[]

--------------------------------------------------------------------------------
-- Type
--------------------------------------------------------------------------------

---@class IssueType
---@field id string
---@field name string
---@field description string|nil
---@field subtask boolean

--------------------------------------------------------------------------------
-- Transition
--------------------------------------------------------------------------------

---@class IssueTransition
---@field id string
---@field name string
---@field to_status_id string|nil
---@field to_status_name string|nil
---@field to_status_category string|nil
---@field to_status_color string|nil

--------------------------------------------------------------------------------
-- Comment
--------------------------------------------------------------------------------

---@class IssueComment
---@field id string
---@field self string|nil
---@field url string|nil
---@field author IssueUser|nil
---@field body string|nil
---@field created string|nil
---@field updated string|nil
---@field parent_id string|number|nil
---@field children IssueComment[]|nil
---@field reactions table<string, number>|nil
---@field deleted boolean|nil
---@field _raw table|nil

--------------------------------------------------------------------------------
-- History
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Activity / reactions
--------------------------------------------------------------------------------

---@class IssueActivityBodyHlSpan
---@field start_col integer
---@field end_col integer
---@field hl_group string

---@alias IssueActivityBodyHlFn fun(row: string, row_index: integer): IssueActivityBodyHlSpan[]|nil

---@class IssueActivityEntry
---@field kind string
---@field actor IssueUser|nil
---@field date string|nil
---@field label string|nil
---@field body string|nil
---@field body_hl IssueActivityBodyHlFn|nil
---@field deleted boolean|nil
---@field always_render boolean|nil

---@alias IssueConversationItemKind "comment"|"description"|"activity"

---@class IssueConversationItem
---@field id string
---@field kind IssueConversationItemKind
---@field created_at string
---@field entity IssueComment|IssueDetails|IssueActivityEntry

---@class IssueReactionOption
---@field key string
---@field emoji string
---@field label string
