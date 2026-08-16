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
---@field fetch_ref string|nil Remote ref used instead of `refs/heads/<branch>`.
---@field https_url string|nil Provider-advertised HTTPS Git URL.
---@field ssh_url string|nil Provider-advertised SSH Git URL.

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
---@field state "open"|"merged"|"declined"|"draft"
---@field author PullsAuthor
---@field source PullsRef
---@field destination PullsRef
---@field comments_count number
---@field created_on string
---@field updated_on string
---@field link PullsLink
---@field provider string
---@field workspace string
---@field repo string
---@field is_starred boolean|nil
---@field reviewers PullsReviewer[]|nil

---@class PullRequestDetails
---@field description string
---@field is_subscribed boolean|nil
---@field assignees PullsAuthor[]|nil
---@field labels PullsLabel[]|nil

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

---@class PullsRepoIssue
---@field number integer|string
---@field title string
---@field state "open"|"closed"
---@field author string
---@field created_at string
---@field comments integer
---@field url string
---@field issue_type { name: string, color: string }|nil

--------------------------------------------------------------------------------
-- Reviewer
--------------------------------------------------------------------------------

---@class PullsReviewer: PullsAuthor
---@field provider_id string|nil Identifier used when updating the reviewer list.
---@field role "reviewer"|"participant"
---@field decision "approved"|"changes_requested"|"reviewed"|"pending"

--------------------------------------------------------------------------------
-- Pipeline
--------------------------------------------------------------------------------

---@alias PullsPipelineState "UNKNOWN"|"STOPPED"|"SUCCESSFUL"|"INPROGRESS"|"FAILED"

---@class PullsPipeline
---@field id string
---@field name string
---@field state PullsPipelineState
---@field provider_state string|nil
---@field provider_context string|nil Raw commit-status context when this pipeline represents a commit status.
---@field url string|nil
---@field job_count integer|nil
---@field stages PullsPipelineStage[]

---@class PullsPipelineStage
---@field name string|nil Nil when the provider has no native stage hierarchy.
---@field state PullsPipelineState
---@field jobs PullsPipelineJob[]

---@class PullsPipelineJob
---@field id string
---@field name string
---@field state PullsPipelineState
---@field provider_state string|nil
---@field provider_context string|nil Raw commit-status context when this job represents a commit status.
---@field url string|nil
---@field started_at string|nil
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
---@field resolved_on string|nil
---@field resolved_by PullsAuthor|nil
---@field inline PullsInlineCommentPosition|nil
---@field file PullsFileCommentPosition|nil
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

---@alias PullsReviewHistoryState "approved"|"changes_requested"|"commented"|"dismissed"|"reviewed"|"unapproved"

---@class PullsReviewHistoryEntry
---@field id string|nil
---@field author PullsAuthor|nil
---@field state PullsReviewHistoryState
---@field submitted_on string
---@field body string|nil
---@field commit_hash string|nil
---@field url string|nil
---@field previous_state PullsReviewHistoryState|nil

---@class PullsReviewData
---@field review PullsReview
---@field comments PullsComment[]
---@field tasks PullsComment[]
---@field reviewers PullsReviewer[]
---@field history PullsReviewHistoryEntry[]

---@class PullsReviewContext
---@field mention_candidates PullsAuthor[]
---@field reviewed_files table<string, boolean>|nil

--------------------------------------------------------------------------------
-- Conversation
--------------------------------------------------------------------------------

---@alias PullsConversationItemKind "comment"|"review"|"activity"

---@class PullsConversationItem
---@field id string
---@field kind PullsConversationItemKind
---@field created_on string
---@field entity PullsComment|PullsReviewHistoryEntry|PullsActivityEntry

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
-- Detail UI
--------------------------------------------------------------------------------

---@class PullsDetailHeaderField
---@field label string
---@field value string
---@field hl string|table[]|nil hl group name, or list of {start_col, end_col, hl_group} relative to the value

---@class PullsDetailChip
---@field label string
---@field hl string|nil

---@class PullsProviderDetail
---@field header_fields (fun(pr: PullRequest, details: PullRequestDetails|nil, loading: boolean): PullsDetailHeaderField[])|nil
---@field chips (fun(pr: PullRequest, details: PullRequestDetails|nil, loading: boolean): PullsDetailChip[])|nil
---@field tabs (fun(): PullsDetailTab[])|nil

---@class PullsDetailTabModule
---@field render fun(pr: PullRequest, details: PullRequestDetails|nil, width: integer): string[], table[], table<integer, table>|nil
---@field on_select (fun(pr: PullRequest, refresh: fun(), opts: { force_refresh: boolean|nil }|nil))|nil
---@field reset (fun())|nil
---@field activate (fun(buf: integer, refresh: fun()))|nil
---@field deactivate (fun(buf: integer))|nil
---@field is_loading (fun(): boolean)|nil
---@field is_selectable_line (fun(lnum: integer, entry: table): boolean)|nil
---@field on_enter (fun(pr: PullRequest, entry: table): boolean|nil)|nil

---@class PullsDetailTab
---@field key string
---@field label string
---@field icon AtlasIconStyle|nil
---@field mod PullsDetailTabModule

---@class PullsProviderRepoDetail
---@field tabs (fun(): PullsRepoDetailTab[])|nil

---@class PullsRepoDetailTabModule
---@field render fun(repo: PullsRepo, width: integer): string[], table[], table<integer, table>|nil
---@field on_select (fun(repo: PullsRepo, refresh: fun(), opts: { force_refresh: boolean|nil }|nil))|nil
---@field reset (fun())|nil
---@field activate (fun(buf: integer, refresh: fun()))|nil
---@field deactivate (fun(buf: integer))|nil
---@field is_loading (fun(): boolean)|nil
---@field is_selectable_line (fun(lnum: integer, entry: table): boolean)|nil
---@field on_enter (fun(repo: PullsRepo, entry: table): boolean|nil)|nil

---@class PullsRepoDetailTab
---@field key string
---@field label string
---@field icon AtlasIconStyle|nil
---@field mod PullsRepoDetailTabModule
