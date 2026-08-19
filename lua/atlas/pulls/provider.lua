--------------------------------------------------------------------------------
-- Main render result
--------------------------------------------------------------------------------

---@class PullsMainRenderResult
---@field lines string[]
---@field spans table[]
---@field line_map table<integer, table>

--------------------------------------------------------------------------------
-- Provider Interface
--------------------------------------------------------------------------------

---@class PullsFetchOpts
---@field force_load boolean|nil
---@field force_refresh boolean|nil
---@field pagelen number|nil
---@field state "open"|"merged"|"declined"|nil

---@class AtlasPullsCommentCompletionContext
---@field pr PullRequest
---@field comments PullsComment[]
---@field tasks PullsComment[]|nil
---@field reviewers PullsReviewer[]|nil
---@field conversation PullsComment[]|nil
---@field review_context PullsReviewContext|nil

---@class PullsProvider
---@field id string
---@field name string
---@field icon string
---@field hl_group string
---@field resolve fun(value: string, parsed: AtlasParsedUrl|nil): AtlasTarget|nil, string|nil
---@field search_view fun(target: AtlasTarget): AtlasPullsViewConfig
---@field target fun(info: AtlasGitRemoteInfo, domain: AtlasDomain, entity: AtlasEntity, number: integer|nil, base_url: string): AtlasTarget
---@field repositories fun(options: table): string[]
---@field capabilities PullsProviderCapabilities

---@class PullsProviderCapabilities
---@field core PullsCoreCapability
---@field comments PullsCommentsCapability|nil
---@field reviews PullsReviewsCapability|nil
---@field tasks PullsTasksCapability|nil
---@field repository PullsRepositoryCapability|nil
---@field pipelines PullsPipelinesCapability|nil
---@field notifications AtlasNotificationsCapability|nil
---@field actions PullsActionsCapability|nil
---@field ui PullsUICapability|nil

---@class PullsCoreCapability
---@field fetch_user fun(on_done: fun(user: PullsUser|nil, err: string|nil)): { cancel: fun() }|nil
---@field fetch_pullrequests fun(view: AtlasPullsViewConfig, opts: PullsFetchOpts, on_done: fun(pulls: PullRequest[], err: string[]|nil)): { cancel: fun() }|nil
---@field fetch_pullrequest fun(pr: PullRequestRef, opts: PullsFetchOpts, on_done: fun(pr: PullRequest|nil, err: string|nil)): { cancel: fun() }|nil
---@field create_pr fun(opts: PullsCreatePROpts, on_done: fun(result: PullsCreatePRResult|nil, err: string|nil)): { cancel: fun() }|nil
---@field update_title fun(pr: PullRequest, title: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil
---@field update_description (fun(pr: PullRequest, description: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field set_draft fun(pr: PullRequest, draft: boolean, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil
---@field decline fun(pr: PullRequest, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil
---@field fetch_default_reviewers fun(opts: { repo_slug: string, repo_root: string|nil, head: string, base: string, pr: PullRequest|nil }, on_done: fun(reviewers: PullsCreatePRReviewer[]|nil, err: string|nil)): { cancel: fun() }|nil
---@field fetch_description (fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(description: string|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_reviewers (fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(reviewers: PullsReviewer[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field update_reviewers fun(pr: PullRequest, reviewers: PullsCreatePRReviewer[], original: PullsCreatePRReviewer[], on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil
---@field fetch_merge_checks (fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(checks: PullsMergeCheck[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_diffstat (fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(entries: PullsDiffstatEntry[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_activity (fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(entries: PullsActivityEntry[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_commits (fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(commits: PullsCommit[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_diff (fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(files: DiffFile[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field views fun(): AtlasPullsViewConfig[]

---@class PullsAddCommentOpts
---@field parent PullsComment|nil          -- reply to this comment
---@field inline PullsInlineCommentPosition|nil
---@field file PullsFileCommentPosition|nil
---@field pending boolean|nil              -- add the comment to a pending review
---@field review PullsReview|nil

---@class PullsCommentsCapability
---@field reaction_options PullsReactionOption[]|nil
---@field comment_completion (fun(context: AtlasPullsCommentCompletionContext): AtlasMarkdownCompletionProvider|nil)|nil
---@field fetch_conversation (fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(result: { comments: PullsComment[], tasks: PullsComment[]|nil, events: PullsActivityEntry[] }|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field add_comment (fun(pr: PullRequest, content: string, opts: PullsAddCommentOpts|nil, on_done: fun(comment: PullsComment|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field edit_comment (fun(pr: PullRequest, comment: PullsComment, on_done: fun(comment: PullsComment|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field delete_comment (fun(pr: PullRequest, target: PullsComment, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field add_reaction (fun(pr: PullRequest, comment: PullsComment, key: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field set_thread_resolved (fun(pr: PullRequest, root: PullsComment, resolved: boolean, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil

---@class PullsReviewsCapability
---@field fetch fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(data: PullsReviewData|nil, err: string|nil)): { cancel: fun() }|nil
---@field fetch_review_context (fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(context: PullsReviewContext|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field start_review (fun(pr: PullRequest, review: PullsReview, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field submit_review (fun(pr: PullRequest, review: PullsReview|nil, body: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field approve (fun(pr: PullRequest, review: PullsReview|nil, body: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field request_changes (fun(pr: PullRequest, review: PullsReview|nil, body: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field discard_review (fun(pr: PullRequest, review: PullsReview, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field set_file_reviewed (fun(pr: PullRequest, path: string, reviewed: boolean, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil

---@class PullsTasksCapability
---@field add_task (fun(pr: PullRequest, content: string, parent: PullsComment|nil, on_done: fun(comment: PullsComment|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field edit_task (fun(task: PullsComment, on_done: fun(task: PullsComment|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field delete_task (fun(task: PullsComment, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil

---@class PullsRepositoryCapability
---@field fetch_details fun(repo: PullsRepo, opts: PullsFetchOpts, on_done: fun(repo: PullsRepoDetails|nil, err: string|nil)): { cancel: fun() }|nil
---@field fetch_branches fun(repo: PullsRepoDetails, opts: PullsFetchOpts, on_done: fun(branches: PullsRepoBranches|nil, err: string|nil)): { cancel: fun() }|nil
---@field fetch_tags fun(repo: PullsRepoDetails, opts: PullsFetchOpts, on_done: fun(tags: PullsRepoTags|nil, err: string|nil)): { cancel: fun() }|nil
---@field fetch_issues (fun(repo: PullsRepoDetails, state: "open"|"closed", opts: PullsFetchOpts, on_done: fun(result: { entries: PullsRepoIssue[], counts: { open: integer, closed: integer }|nil }|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field delete_branch (fun(repo: PullsRepoDetails, branch: PullsRepoBranch, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil

---@class PullsPipelinesCapability
---@field fetch fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(pipelines: PullsPipeline[]|nil, err: string|nil)): { cancel: fun() }|nil
---@field fetch_commit_status (fun(commit: PullsCommit, opts: { force_refresh: boolean|nil }|nil, on_done: fun(status: string|nil, url: string|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_details (fun(pr: PullRequest, pipeline: PullsPipeline, opts: { force_refresh: boolean|nil }|nil, on_done: fun(pipeline: PullsPipeline|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_job_log (fun(pr: PullRequest, pipeline: PullsPipeline, job: PullsPipelineJob, on_done: fun(log: string|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field actions PullsPipelineAction[]|nil

---@class PullsActionsCapability
---@field items AtlasPullAction[]
---@field is_available fun(action_id: string, ctx: AtlasPullActionContext): boolean
---@field run fun(action_id: string, ctx: AtlasPullActionContext, on_done: fun(result: PullsActionResult|nil, err: string|nil)): boolean

---@class PullsUICapability
---@field setup fun()|nil
---@field render (fun(pulls: PullRequest[], layout: "compact"|"grouped"|"plain", opts: { width: integer }): PullsMainRenderResult)|nil
---@field panel PullsProviderPRPanel|nil
---@field repo_panel PullsProviderRepoPanel|nil
