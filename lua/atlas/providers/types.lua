---@class AtlasUser
---@field id string|nil
---@field name string
---@field username string|nil

---@class AtlasProviderCapabilities
---@field repository AtlasRepositoryCapability|nil
---@field notifications AtlasNotificationsCapability|nil
---@field users AtlasUsersCapability|nil

---@class AtlasUsersCapability
---@field fetch_user fun(on_done: fun(user: AtlasUser|nil, err: string|nil)): { cancel: fun() }|nil
---@field list_members (fun(project_path: string, query: string|nil, on_done: fun(users: AtlasUser[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field get_assignable_users (fun(slug: string, query: string|nil, on_done: fun(users: AtlasUser[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil

---@alias AtlasRelationship
---| "closes"
---| "closed by"
---| "blocks"
---| "blocked by"
---| "is blocked by"
---| "parent"
---| "sub-issue"
---| "child"
---| "references"
---| "referenced by"
---| "relates to"
---| "linked"
---| string

---@class AtlasRelatedItem
---@field kind "issue"|"pr"|"external"
---@field url string Canonical web URL; never resolved relative to the current repository.
---@field key string|nil
---@field title string|nil
---@field relationship AtlasRelationship|nil

---@class AtlasRepository
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

---@class AtlasRepositoryDetails : AtlasRepository
---@field description string|nil
---@field topics string[]|nil
---@field size number|nil
---@field default_branch string|nil
---@field is_private boolean|nil
---@field readme string|nil

---@class AtlasRepositoryBranch
---@field name string
---@field hash string
---@field date string|nil
---@field message string|nil
---@field author string|nil
---@field protected boolean|nil
---@field api_url string|nil

---@class AtlasRepositoryBranches
---@field entries AtlasRepositoryBranch[]

---@class AtlasRepositoryCapability
---@field fetch_details fun(repo: AtlasRepository, opts: PullsFetchOpts, on_done: fun(repo: AtlasRepositoryDetails|nil, err: string|nil)): { cancel: fun() }|nil
---@field fetch_branches fun(repo: AtlasRepositoryDetails, opts: PullsFetchOpts, on_done: fun(branches: AtlasRepositoryBranches|nil, err: string|nil)): { cancel: fun() }|nil
---@field fetch_tags fun(repo: AtlasRepositoryDetails, opts: PullsFetchOpts, on_done: fun(tags: PullsRepoTags|nil, err: string|nil)): { cancel: fun() }|nil
---@field fetch_issues (fun(repo: AtlasRepositoryDetails, state: "open"|"closed", opts: PullsFetchOpts, on_done: fun(result: { entries: PullsRepoIssue[], counts: { open: integer, closed: integer }|nil }|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field delete_branch (fun(repo: AtlasRepositoryDetails, branch: AtlasRepositoryBranch, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
