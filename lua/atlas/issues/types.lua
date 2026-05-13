--------------------------------------------------------------------------------
-- User
--------------------------------------------------------------------------------

---@class IssueUser
---@field account_id string
---@field display_name string
---@field email string

--------------------------------------------------------------------------------
-- Project
--------------------------------------------------------------------------------

---@class IssueProject
---@field id string
---@field key string
---@field name string
---@field self string
---@field category table|nil

--------------------------------------------------------------------------------
--  Issue
--------------------------------------------------------------------------------
-- TODO: This has been mainly started with Jira so its pretty much jira specific, it currently works with github as well but i should probably refactor this at some point.

---@class Issue
---@field key string
---@field summary string
---@field project IssueProject|nil
---@field status string|nil
---@field status_id string|nil
---@field status_category string|nil
---@field status_color string|nil
---@field type IssueType|nil
---@field priority string|nil
---@field assignee IssueUser|nil
---@field reporter IssueUser|nil
---@field story_points number|nil
---@field duedate string|nil
---@field parent Issue|nil
---@field url string|nil
---@field is_pinned boolean|nil
---@field is_subscribed boolean|nil
---@field _raw any|nil

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
---@field _body table|nil
---@field created string|nil
---@field updated string|nil
---@field parent_id string|number|nil
---@field children IssueComment[]|nil
---@field reactions table<string, number>|nil

--------------------------------------------------------------------------------
-- History
--------------------------------------------------------------------------------

---@class IssueHistoryItem
---@field field string|nil
---@field field_type string|nil
---@field from string|nil
---@field from_string string|nil
---@field to string|nil
---@field to_string string|nil

---@class IssueHistoryEntry
---@field id string
---@field created string|nil
---@field author IssueUser|nil
---@field items IssueHistoryItem[]
