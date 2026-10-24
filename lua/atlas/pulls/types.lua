--------------------------------------------------------------------------------
-- Author
--------------------------------------------------------------------------------

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
---@field author AtlasUser
---@field source PullsRef
---@field destination PullsRef
---@field comments_count number
---@field created_on string
---@field updated_on string
---@field link PullsLink
---@field provider string
---@field repo AtlasRepository
---@field is_starred boolean|nil
---@field reviewers PullsReviewer[]|nil

---@class PullRequestDetails
---@field description string
---@field reactions AtlasReaction[]|nil
---@field is_subscribed boolean|nil
---@field assignees AtlasUser[]|nil
---@field labels PullsLabel[]|nil

--------------------------------------------------------------------------------
-- Reviewer
--------------------------------------------------------------------------------

---@class PullsReviewer: AtlasUser
---@field provider_id string|nil Identifier used when updating the reviewer list.
---@field role "reviewer"|"participant"
---@field decision "approved"|"changes_requested"|"reviewed"|"pending"

---@class PullsReviewerCandidate
---@field label string
---@field provider_id string
---@field selected boolean|nil

--------------------------------------------------------------------------------
-- Merge check
--------------------------------------------------------------------------------

---@class PullsMergeCheckDetail
---@field text string
---@field text_hl string|nil
---@field icon string
---@field icon_hl string|nil

---@class PullsMergeCheck
---@field key string
---@field state "successful"|"failed"|"inprogress"|"warning"|"muted"
---@field label string
---@field details (string|PullsMergeCheckDetail)[]|nil

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

---@alias PullsActivityKind
---| "comment"
---| "comment_deleted"
---| "review"
---| "approval"
---| "unapproval"
---| "changes_requested"
---| "review_dismissed"
---| "review_requested"
---| "committed"
---| "update"
---| "force_pushed"
---| "closed"
---| "merged"
---| "reopened"
---| "ready_for_review"
---| "convert_to_draft"
---| "labeled"
---| "unlabeled"
---| "assigned"
---| "unassigned"
---| "renamed"

---@class PullsActivityEntry
---@field kind PullsActivityKind
---@field actor AtlasUser|nil
---@field date string
---@field label string|nil
---@field body string|nil
---@field deleted boolean|nil

--------------------------------------------------------------------------------
-- Comment
--------------------------------------------------------------------------------

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
---@field author AtlasUser|nil
---@field author_roles string[]|nil
---@field body string
---@field body_display string|nil
---@field created_at string
---@field resolved_at string|nil
---@field resolved_by AtlasUser|nil
---@field inline PullsInlineCommentPosition|nil
---@field hunk DiffHunkLines|nil
---@field file PullsFileCommentPosition|nil
---@field is_task boolean|nil                            -- true = render as task (checkbox)
---@field state "RESOLVED"|"OUTDATED"|nil                -- nil = active/open
---@field deleted boolean|nil
---@field pending boolean|nil                            -- Draft comments can also be resolved.
---@field outdated boolean|nil                           -- may coexist with RESOLVED
---@field reactions AtlasReaction[]|nil
---@field url string|nil

---@class AtlasCommentThreadNode
---@field comment PullsComment
---@field children AtlasCommentThreadNode[]

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
---@field author AtlasUser|nil
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
---@field reviewed_files table<string, boolean>
---@field outdated_files table<string, boolean>

--------------------------------------------------------------------------------
-- Conversation
--------------------------------------------------------------------------------

---@class PullsConversation
---@field description PullsComment|nil
---@field comments PullsComment[]
---@field reviews PullsReviewHistoryEntry[]
---@field activities PullsActivityEntry[]

--------------------------------------------------------------------------------
-- Commit
--------------------------------------------------------------------------------

---@class PullsCommit
---@field hash string
---@field repo_full_name string|nil
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

---@class PullsDetailKeymap
---@field key string|string[]
---@field desc string
---@field callback fun()

---@class PullsProviderDetail
---@field header_fields (fun(pr: PullRequest, details: PullRequestDetails|nil, loading: boolean): PullsDetailHeaderField[])|nil
---@field chips (fun(pr: PullRequest, details: PullRequestDetails|nil, loading: boolean): PullsDetailChip[])|nil
---@field tabs (fun(): PullsDetailTab[])|nil
---@field keymaps (fun(): PullsDetailKeymap[])|nil

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
