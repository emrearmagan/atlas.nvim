--------------------------------------------------------------------------------
-- Author
--------------------------------------------------------------------------------

---@class PullsAuthor
---@field name string
---@field id string
---@field username string
---@field nickname string|nil

--------------------------------------------------------------------------------
-- Refs
--------------------------------------------------------------------------------

---@class PullsRef
---@field branch string
---@field commit_hash string

--------------------------------------------------------------------------------
-- Links
--------------------------------------------------------------------------------

---@class PullsLink
---@field html string

--------------------------------------------------------------------------------
-- Pull Request
--------------------------------------------------------------------------------

---@class PullRequest
---@field id string|number
---@field title string
---@field description string
---@field state "open"|"merged"|"declined"|"draft"
---@field author PullsAuthor
---@field source PullsRef
---@field destination PullsRef
---@field comments_count number
---@field tasks_count number
---@field created_on string
---@field updated_on string
---@field link PullsLink
---@field provider string
---@field workspace string
---@field repo string
---@field repo_full_name string
---@field is_subscribed boolean|nil
---@field _raw table|nil

--------------------------------------------------------------------------------
-- User (current authenticated user)
--------------------------------------------------------------------------------

---@class PullsUser
---@field name string
---@field id string
---@field username string

--------------------------------------------------------------------------------
-- Repository
--------------------------------------------------------------------------------

---@class PullsRepo
---@field id string
---@field name string
---@field owner string|nil
---@field repo_name string|nil
---@field html_url string|nil

---@class PullsRepoDetails : PullsRepo
---@field full_name string|nil
---@field owner string|nil
---@field repo_name string|nil
---@field html_url string|nil
---@field description string|nil
---@field size number|nil
---@field default_branch string|nil
---@field is_private boolean|nil
---@field created_on string|nil
---@field readme string|nil
---@field _raw table|nil

---@class PullsRepoBranch
---@field name string
---@field hash string
---@field date string
---@field message string
---@field author string
---@field api_url string|nil

---@class PullsRepoBranches
---@field entries PullsRepoBranch[]

---@class PullsRepoTag
---@field name string
---@field hash string
---@field date string
---@field message string
---@field author string

---@class PullsRepoTags
---@field entries PullsRepoTag[]

--------------------------------------------------------------------------------
-- Group (PRs grouped by repository)
--------------------------------------------------------------------------------

---@class PullsGroup
---@field repo PullsRepo
---@field prs PullRequest[]

--------------------------------------------------------------------------------
-- Reviewer
--------------------------------------------------------------------------------

---@class PullsReviewer
---@field name string
---@field nickname string|nil
---@field decision "approved"|"changes_requested"|"pending"

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

---@class PullsBuild
---@field name string
---@field state string
---@field url string|nil
---@field key string|nil

--------------------------------------------------------------------------------
-- Merge check
--------------------------------------------------------------------------------

---@class PullsMergeCheck
---@field key string
---@field state "successful"|"failed"|"inprogress"|"warning"|"muted"
---@field label string
---@field details string[]|nil

--------------------------------------------------------------------------------
-- Diffstat
--------------------------------------------------------------------------------

---@class PullsDiffstatEntry
---@field status "added"|"removed"|"renamed"|"modified"|"deleted"
---@field path string
---@field old_path string|nil
---@field lines_added number
---@field lines_removed number

--------------------------------------------------------------------------------
-- Activity
--------------------------------------------------------------------------------

---@class PullsActivityEntry
---@field kind "approval"|"changes_requested"|"comment"|"update"|string
---@field actor PullsAuthor|nil
---@field date string
---@field content_raw string|nil
---@field deleted boolean|nil
---@field changes table|nil
---@field source_branch string|nil
---@field target_branch string|nil

--------------------------------------------------------------------------------
-- Comment
--------------------------------------------------------------------------------

---@class PullsComment
---@field id number
---@field parent_id number|nil
---@field author {name: string, nickname: string|nil, id: string|nil}|nil
---@field content_raw string
---@field created_on string
---@field deleted boolean|nil
---@field inline {path: string, to: number|nil, from: number|nil}|nil
---@field url string|nil
---@field html_url string|nil

--------------------------------------------------------------------------------
-- Commit
--------------------------------------------------------------------------------

---@class PullsCommit
---@field hash string
---@field short_hash string|nil
---@field message string
---@field author_name string
---@field author_nickname string|nil
---@field date string
---@field html_url string|nil
---@field statuses_url string|nil

--------------------------------------------------------------------------------
-- Conversation snapshot
--------------------------------------------------------------------------------

---@class PullsCommentThread
---@field root PullsComment
---@field replies PullsComment[]

---@class PullsFileThread
---@field path string
---@field side "old"|"new"|nil
---@field line integer|nil
---@field start_line integer|nil
---@field hunk DiffHunk|nil
---@field threads PullsCommentThread[]

---@class PullsTask
---@field id string|number
---@field comment_id string|number|nil
---@field content_raw string
---@field state "OPEN"|"RESOLVED"|string
---@field creator PullsAuthor|nil
---@field created_on string
---@field updated_on string|nil
---@field _raw any|nil

---@class PullsConversationSnapshot
---@field general PullsCommentThread[]
---@field file_threads PullsFileThread[]
---@field tasks PullsTask[]|nil

