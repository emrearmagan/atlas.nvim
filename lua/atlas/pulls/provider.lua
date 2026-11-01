---@alias PullsStateFilter "open"|"merged"|"declined"

---@class AtlasPullsBookmarkConfig
---@field layout AtlasPullsViewLayout|nil
---@field search string|nil

---@class PullsFetchOpts
---@field force_refresh boolean|nil
---@field pagelen number|nil
---@field cursor table<string, string>|nil

---@class PullsPage
---@field items PullRequest[]
---@field query string|nil
---@field next_cursor table<string, string>|nil
---@field total_pages integer|nil

---@class PullsProvider
---@field id string
---@field name string
---@field icon string
---@field hl_group string
---@field views fun(): AtlasPullsViewConfig[]
---@field repository_view fun(repository: AtlasTarget, branch: string|nil): AtlasPullsViewConfig
---@field resolve_search fun(view: AtlasPullsViewConfig): string, PullsStateFilter[]
---@field capabilities PullsProviderCapabilities

---@class PullsProviderCapabilities : AtlasProviderCapabilities
---@field core PullsCoreCapability
---@field write PullsWriteCapability|nil
---@field comments PullsCommentsCapability|nil
---@field reviews PullsReviewsCapability|nil
---@field tasks PullsTasksCapability|nil
---@field pipelines PullsPipelineBackend|nil
---@field ui PullsUICapability|nil

---@class PullsMergeOpts
---@field method "merge"|"squash"
---@field delete_source_branch boolean
---@field subject string|nil
---@field body string|nil

---@class PullsCoreCapability
---@field fetch_pullrequests fun(view: AtlasPullsViewConfig, opts: PullsFetchOpts, on_done: fun(page: PullsPage, err: string[]|nil)): { cancel: fun() }|nil Fetch the view, including when its states have not been initialized by the dashboard.
---@field fetch_by_refs fun(refs: PullRequestRef[], opts: PullsFetchOpts, on_done: fun(pulls: PullRequest[], err: string|nil)): { cancel: fun() }|nil
---@field fetch_pullrequest fun(ref: PullRequestRef, opts: PullsFetchOpts, on_done: fun(details: PullRequestDetails|nil, err: string|nil)): { cancel: fun() }|nil
---@field fetch_links (fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(links: AtlasRelatedItem[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field decline fun(pr: PullRequest, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil
---@field merge fun(pr: PullRequest, opts: PullsMergeOpts, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil
---@field fetch_description fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(description: string|nil, err: string|nil)): { cancel: fun() }|nil
---@field fetch_reviewers fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(reviewers: PullsReviewer[]|nil, err: string|nil)): { cancel: fun() }|nil
---@field fetch_merge_checks (fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(checks: PullsMergeCheck[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_diffstat (fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(entries: PullsDiffstatEntry[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_commits (fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(commits: PullsCommit[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil

---@class PullsWriteCapability
---@field create (fun(opts: PullsCreatePROpts, on_done: fun(result: PullsCreatePRResult|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field update (fun(pr: PullRequest, opts: PullsUpdatePROpts, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_reviewer_candidates (fun(opts: { repo_slug: string, pr: PullRequest|nil }, on_done: fun(reviewers: PullsReviewerCandidate[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_labels (fun(repo_slug: string, on_done: fun(labels: PullsLabel[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_assignees (fun(repo_slug: string, on_done: fun(users: AtlasUser[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil

---@class PullsAddCommentOpts
---@field parent PullsComment|nil          -- reply to this comment
---@field inline PullsInlineCommentPosition|nil
---@field file PullsFileCommentPosition|nil
---@field pending boolean|nil              -- add the comment to a pending review
---@field review PullsReview|nil

---@class PullsCommentsCapability
---@field fetch_conversation (fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(conversation: PullsConversation|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field add_comment (fun(pr: PullRequest, content: string, opts: PullsAddCommentOpts|nil, on_done: fun(comment: PullsComment|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field edit_comment (fun(pr: PullRequest, comment: PullsComment, content: string, on_done: fun(comment: PullsComment|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field delete_comment (fun(pr: PullRequest, target: PullsComment, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field reactions AtlasReactionsCapability|nil
---@field set_thread_resolved (fun(pr: PullRequest, root: PullsComment, resolved: boolean, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil

---@class PullsReviewsCapability
---@field fetch fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(data: PullsReviewData|nil, err: string|nil)): { cancel: fun() }|nil
---@field fetch_threads fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(data: PullsReviewData|nil, err: string|nil)): { cancel: fun() }|nil
---@field edit_review (fun(pr: PullRequest, review_id: string, body: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_review_context (fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(context: PullsReviewContext|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field start_review (fun(pr: PullRequest, review: PullsReview, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field submit_review (fun(pr: PullRequest, review: PullsReview|nil, body: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field approve (fun(pr: PullRequest, review: PullsReview|nil, body: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field request_changes (fun(pr: PullRequest, review: PullsReview|nil, body: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field discard_review (fun(pr: PullRequest, review: PullsReview, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field set_files_reviewed (fun(pr: PullRequest, paths: string[], reviewed: boolean, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil

---@class PullsTasksCapability
---@field add_task (fun(pr: PullRequest, content: string, parent: PullsComment|nil, on_done: fun(comment: PullsComment|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field edit_task (fun(task: PullsComment, on_done: fun(task: PullsComment|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field delete_task (fun(task: PullsComment, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil

---@class PullsUICapability
---@field detail PullsProviderDetail|nil
---@field repository { pages: RepositoryPage[] }|nil
