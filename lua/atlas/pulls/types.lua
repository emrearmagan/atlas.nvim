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
---@field fetch_remote string|nil Git remote name or URL used to fetch this ref.
---@field fetch_ref string|nil Remote ref used instead of `refs/heads/<branch>`.

--------------------------------------------------------------------------------
-- Links
--------------------------------------------------------------------------------

---@class PullsLink
---@field html string

---@class PullsLabel
---@field name string
---@field color string|nil

--------------------------------------------------------------------------------
-- Pull Request
--------------------------------------------------------------------------------

---@class PullRequestRef
---@field id string|number
---@field repo_full_name string

---@class PullRequest : PullRequestRef
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
---@field is_subscribed boolean|nil
---@field reactions table<string, integer>|nil
---@field assignees PullsAuthor[]|nil
---@field reviewers PullsReviewer[]|nil
---@field labels PullsLabel[]|nil
---@field lines_added number|nil
---@field lines_removed number|nil
---@field _raw table

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
---@field full_name string|nil
---@field workspace string|nil
---@field created_on string|nil
---@field stars number|nil
---@field watchers number|nil
---@field forks number|nil

---@class PullsRepoDetails : PullsRepo
---@field description string|nil
---@field size number|nil
---@field default_branch string|nil
---@field is_private boolean|nil
---@field readme string|nil
---@field _raw table|nil

---@class PullsRepoBranch
---@field name string
---@field hash string
---@field date string|nil
---@field message string|nil
---@field author string|nil
---@field api_url string|nil

---@class PullsRepoBranches
---@field entries PullsRepoBranch[]

---@class PullsRepoTag
---@field name string
---@field hash string
---@field date string|nil
---@field message string|nil
---@field author string|nil

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

---@class PullsReviewer: PullsAuthor
---@field provider_id string|nil Identifier used when updating the reviewer list.
---@field decision "approved"|"changes_requested"|"pending"

--------------------------------------------------------------------------------
-- Pipeline
--------------------------------------------------------------------------------

---@class PullsPipeline
---@field name string
---@field state string
---@field provider_state string|nil
---@field url string|nil
---@field key string|nil
---@field provider_id string|nil
---@field commit_hash string|nil
---@field jobs PullsPipelineJob[]

---@class PullsPipelineJob
---@field id string|integer
---@field name string
---@field state string
---@field provider_state string|nil
---@field url string|nil
---@field stage string|nil
---@field started_at string|nil
---@field completed_at string|nil
---@field duration number|nil Seconds
---@field steps PullsPipelineStep[]|nil

---@class PullsPipelineStep
---@field id string|integer
---@field name string
---@field state string
---@field provider_state string|nil
---@field started_at string|nil
---@field completed_at string|nil
---@field duration number|nil Seconds

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
---@field kind string
---@field actor PullsAuthor|nil
---@field date string
---@field label string|nil
---@field body string|nil
---@field deleted boolean|nil

--------------------------------------------------------------------------------
-- Comment
--------------------------------------------------------------------------------

---@class PullsReactionOption
---@field key string         -- API key
---@field emoji string       -- display glyph
---@field label string|nil   -- optional label

---@class PullsInlineCommentPosition
---@field path string
---@field old_path string|nil
---@field from integer|nil
---@field to integer|nil
---@field start_from integer|nil
---@field start_to integer|nil
---@field commit_hash string|nil

---@class PullsFileCommentPosition
---@field path string
---@field old_path string|nil
---@field commit_hash string|nil

---@class PullsComment
---@field id number|string
---@field parent_id number|string|nil
---@field thread_id string|nil
---@field author PullsAuthor|nil
---@field content_raw string
---@field content_display string|nil
---@field created_on string
---@field inline PullsInlineCommentPosition|nil
---@field file PullsFileCommentPosition|nil
---@field inline_hunk DiffHunk|nil                       -- surrounding diff context for inline comments
---@field inline_hunk_anchor integer|nil                 -- line coordinate inside inline_hunk
---@field is_task boolean|nil                            -- true = render as task (checkbox)
---@field task_label string|nil                          -- display name override; defaults to "Task"
---@field state "PENDING"|"RESOLVED"|"DELETED"|"OUTDATED"|nil -- primary state; nil = active/open
---@field outdated boolean|nil                           -- may coexist with RESOLVED
---@field reactions table<string, integer>|nil
---@field url string|nil
---@field html_url string|nil
---@field _raw table|nil

--------------------------------------------------------------------------------
-- Review
--------------------------------------------------------------------------------

---@class PullsReview
---@field id string|nil
---@field commit_hash string|nil
---@field pending boolean

---@class PullsReviewData
---@field review PullsReview
---@field comments PullsComment[]
---@field tasks PullsComment[]

---@class PullsReviewContext
---@field authors PullsAuthor[]
---@field reviewed_files table<string, boolean>|nil

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
