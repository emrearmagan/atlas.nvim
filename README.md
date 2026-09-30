[![Neovim](https://img.shields.io/badge/Neovim-0.10+-blue.svg)](https://neovim.io/)
[![Version](https://img.shields.io/github/v/tag/emrearmagan/atlas.nvim.svg)](https://github.com/emrearmagan/atlas.nvim/tags)
[![CI](https://github.com/emrearmagan/atlas.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/emrearmagan/atlas.nvim/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/emrearmagan/atlas.nvim?style=flat-square&color=blue)](LICENSE)

# Atlas.nvim

Review pull requests and manage issues across GitHub, GitLab, Bitbucket and Jira without leaving your editor.

<p>
  <img alt="GitHub" src="https://img.shields.io/badge/GitHub-181717?style=flat-square&logo=github&logoColor=white">
  <img alt="Bitbucket" src="https://img.shields.io/badge/Bitbucket-0052CC?style=flat-square&logo=bitbucket&logoColor=white">
  <img alt="GitLab" src="https://img.shields.io/badge/GitLab-FC6D26?style=flat-square&logo=gitlab&logoColor=white">
  <img alt="Jira" src="https://img.shields.io/badge/Jira-0052CC?style=flat-square&logo=jira&logoColor=white">
</p>

**Quick links**

- [Configuration](#configuration)
- [Commands](#commands)
- GitHub: [Pull requests](#github) · [Issues](#github-issues)
- GitLab: [Pull requests](#gitlab) · [Issues](#gitlab-issues)
- [Bitbucket](#bitbucket)
- [Jira](#jira)

<img alt="Atlas UI" src="https://github.com/user-attachments/assets/62909665-e036-44be-bec0-1d27da613eb6" />

> [!CAUTION]
> **Still in early development, will have breaking changes!**

## Installation

<details>
<summary><strong>Using <a href="https://github.com/folke/lazy.nvim">lazy.nvim</a></strong></summary>

```lua
---@module "atlas"

{
  "emrearmagan/atlas.nvim",
  dependencies = {
    "nvim-tree/nvim-web-devicons", -- optional but recommended
    "esmuellert/codediff.nvim", -- optional (PullRequest diff)
    "sindrets/diffview.nvim", -- optional; or "dlyongemallo/diffview-plus.nvim"
  },
  -- See Configuration below
  ---@type AtlasConfig
  opts = {},
}
```

</details>

<details>
<summary><strong>Using <a href="https://neovim.io/doc/user/pack/#vim.pack">vim.pack</a> (Neovim 0.12+)</strong></summary>

```lua
vim.pack.add({
  "https://github.com/emrearmagan/atlas.nvim",
})

-- See Configuration below
require("atlas").setup({})
```

</details>

<details>
<summary><strong>Requirements</strong></summary>

- Neovim: `0.10+`
- `git` and `curl` on `$PATH`
- Jira: Jira Cloud REST API v3 (`*.atlassian.net`) or Jira Server REST API v2
- Bitbucket: Bitbucket Cloud REST API 2.0 (`api.bitbucket.org`)
- GitHub: GitHub CLI (`gh`) authenticated with `gh auth login`
- GitLab: GitLab REST API v4 (`gitlab.com` or self-hosted), Personal Access Token with `api` scope

</details>

> [!tip]
> It's a good idea to run `:checkhealth atlas` to see if everything is set up correctly.

## Features

### Review Pull Requests

<img alt="AtlasDiff" src="https://github.com/user-attachments/assets/38d40d4d-5d1d-4cb5-a597-2d94faabf1a3">

Run `:Atlas review` in a Git repository to pick a pull request, or pass a PR URL directly. Atlas opens it in your configured diff viewer.

- Browse files, commits, hunks, and review history.
- Comment, suggest changes, manage threads, or leave local notes.
- Track tasks, checklists, and reviewed files.
- Submit, approve, request changes, or merge.

> [!NOTE]
> **Alternative viewers:** [CodeDiff](https://github.com/esmuellert/codediff.nvim), [Diffview](https://github.com/sindrets/diffview.nvim), and [Diffview-plus](https://github.com/dlyongemallo/diffview-plus.nvim) can display Atlas comment, task, and local-note overlays, but their integrations rely on plugin internals and may break after upstream changes.

<details>
<summary><strong>Notes</strong> - annotate a diff without posting anything</summary>

Local notes let you leave something on a diff without posting it to the pull request. Each note is attached to a file and line and can be an `ISSUE`, `SUGGESTION`, `NOTE`, or `PRAISE`.

#### Script and integration

For scripts, use `bin/atlas-notes`. Notes added there appear in AtlasDiff, CodeDiff, Diffview, Diffview-plus, and `:Atlas notes`:

```sh
./bin/atlas-notes add \
  --target https://github.com/owner/repository/pull/123 \
  --file lua/review_queue.lua --line 19 \
  --context "local item = queue[index]" \
  --type suggestion --body "Should this be a bool?"
```

My dotfiles include a [Pi extension that wraps this script](https://github.com/emrearmagan/dotfiles/blob/main/config/pi/extensions/atlas-notes.ts) so review agents can list and add notes.

</details>

<details>
<summary><strong>LSP for Reviews</strong> - attach LSP to the new side of a diff</summary>

Use your configured language servers for hover and go-to-definition on the new side of AtlasDiff.

```lua
pulls = {
  diff = {
    lsp = {
      enabled = true,
      -- link = { "node_modules", ".venv" }, -- optional dependencies
    },
  },
}
```

Atlas uses a temporary worktree and removes it when the diff closes. Set `link` to symlink dependency folders from your local checkout. See [Pulls Configuration](#pulls-configuration) for all options.

<img alt="lsp-support" src="https://github.com/user-attachments/assets/9d67cd02-f1fa-4ee3-94ad-d11fa1388dbd" />

</details>

### Also included

<details>
<summary><strong>Repository browser</strong> - Browse repositories from Neovim</summary>

<img alt="repository" src="https://github.com/user-attachments/assets/2462e7ce-7e80-4d6c-badc-d2112c808e12" />

Browse a repository's README, pull requests, issues, builds, branches, tags and releases. Use `:Atlas browse .` for the current repository, or pass a repository URL.

</details>

<details>
<summary><strong>Pipelines</strong> - Browse jobs, steps, and logs</summary>

<p align="center">
  <img width="85%" alt="View pipelines" src="https://github.com/user-attachments/assets/34b76468-6f91-46ee-a86d-608187060a13">
</p>

View pipelines and their jobs, inspect their status, and read job logs directly in Atlas.

Use `:Atlas pipelines <target>` with a branch name, PR URL or number (`123`, `#123`, or GitLab `!123`), or a build URL. Branch names use the local repository; `:Atlas pipelines .` opens builds for the current branch.

#### Pipeline Configuration

Atlas uses your provider's CI by default. Set `ci.backend` to use your own. For Bamboo on Bitbucket, use `require("atlas.pulls.pipelines.bamboo").new(opts)` with `host`, `user`, and `password`.

```lua
providers = {
  github = {
    ci = {
      backend = {
        fetch = function(context, opts, done)
          -- Fetch pipelines with their stages and jobs.
          done({}, nil)
        end,
        fetch_job = function(context, pipeline, job, done)
          -- Fetch the updated job, including any steps.
          done(job, nil)
        end,
        fetch_job_log = function(context, pipeline, job, done)
          -- Fetch the job's raw log output.
          done({ raw = "Your log output here" }, nil)
        end,
        parse = function(log)
          -- Return cleaned lines or your own nested groups.
          return log.lines
        end,
        actions = {
          -- Add your actions here.
        },
      },
      highlights = {
        { pattern = "^FAIL%s", level = "error" },
        { pattern = "deprecated", level = "warn", hl_group = "DiagnosticWarn" },
      },
    },
  },
}
```

`ci.highlights` controls log highlighting using Lua patterns. Set `level` for a severity color or `hl_group` for an existing Neovim highlight group.

</details>

<details>
<summary><strong>Custom actions</strong> - Run project-specific actions for pull requests and issues</summary>

<p align="center">
  <img width="85%" alt="Atlas custom action" src="https://github.com/user-attachments/assets/6d1ebd15-0c48-47d2-b108-b281d492827c">
</p>

Add project-specific actions to pull requests and issues. Custom actions receive the current item and provider context, making it possible to call local scripts, open repositories in tmux, copy branch names, or connect Atlas to your own tooling.

```lua
pulls = {
  repo_config = {
    paths = {
      ["your-workspace/*"] = "~/code/repos/*",
    },
    settings = {},
  },
  custom_actions = {
    {
      id = "show_repo_status",
      label = "Show repository status",
      icon = "",
      ---@param pr PullRequest
      ---@param ctx AtlasPullsCustomActionContext
      ---@param done fun(ok: boolean|nil, message: string|nil)
      run = function(_, ctx, done)
        if not ctx.repo_path then
          done(false, "No repo path")
          return
        end

        local output = ctx.output("Repository status")
        output:write("Checking " .. ctx.repo_path)
        output:run({ "git", "status", "--short" }, function(code)
          if code ~= 0 then
            done(false, "Failed to read repository status")
            return
          end
          done(true, "Repository status loaded")
        end, {
          cwd = ctx.repo_path,
        })
      end,
    },
  },
},
issues = {
  custom_actions = {
    {
      id = "copy_branch_name",
      label = "Copy branch name",
      icon = "",
      ---@param issue Issue
      ---@param ctx AtlasIssuesCustomActionContext
      ---@param done fun(ok: boolean|nil, message: string|nil)
      run = function(issue, ctx, done)
        local branch = string.format("%s/%s", issue.key, issue.title:lower():gsub("%s+", "-"))
        vim.fn.setreg("+", branch)
        done(true, "Copied: " .. branch)
      end,
    },
  },
},
```

Use `ctx.output(title)` to show output from a custom action:

```lua
output:write("Loading...")
output:run(cmd, on_exit, { cwd = "/repo" })
```

</details>

<details>
<summary><strong>Create</strong> - Create pull requests and issues from Neovim</summary>

<p align="center">
  <img width="49%" alt="Create pull request" src="https://github.com/user-attachments/assets/dbaa5fcb-a701-419c-8ad6-a8803a0ffc7d">
  <img width="49%" alt="Create issue" src="https://github.com/user-attachments/assets/8fdc418c-2a29-4a8a-a748-a7daec021984">
</p>

Use `:Atlas create [pr|issue]` to create a pull request from the current branch or a new issue. For pull requests, Atlas can fill the description from your template or commits.

</details>

<details>
<summary><strong>Bookmarks</strong> - Save searches and star items locally</summary>

<p align="center">
  <img width="85%" alt="Bookmarks" src="https://github.com/user-attachments/assets/24e8463a-61c2-4fa7-8240-1425d31c0d61">
</p>

Save searches as bookmarks, or press `*` to star a pull request or issue. Both appear alongside your configured views.

</details>

### Other features

- Compare branches or commits with `:Atlas diff main...HEAD`.
- Search with GitHub queries or Jira JQL, with query completion.
- Use Conventional Comments templates or define your own.
- Save issue descriptions as templates and reuse them when creating issues.
- Close or reopen GitHub/GitLab issues and change Jira workflow states.
- Jump between linked issues and pull requests, or browse related issues and sub-issues.
- Read GitHub and GitLab notifications, open the related item, and mark them as read or done.
- Remap shortcuts or assign multiple keys to the same action.
- Set local repository paths and PR templates per project.

## Configuration

```lua
{
  ui = {
    -- Global statusline for Atlas. See the Statusline section below.
    statusline = true,
    -- "auto", "default", "snacks", or "fzf-lua".
    picker = "auto",
    -- Make the main Atlas dashboard a listed buffer.
    listed_buffer = false,
  },

  providers = {
    ---@type AtlasGitHubConfig
    github = {
      -- hostname = "github.company.com", -- Defaults to GH_HOST, then github.com.
      cache_ttl = 300, -- Set to 0 to disable caching.
    },

    ---@type AtlasGitLabConfig
    gitlab = {
      base_url = "https://gitlab.com",
      -- Personal Access Token with `api` scope:
      -- https://docs.gitlab.com/ee/user/profile/personal_access_tokens.html
      token = vim.env.GITLAB_TOKEN,
      cache_ttl = 300, -- Set to 0 to disable caching.
    },

    ---@type AtlasBitbucketConfig
    bitbucket = {
      user = vim.env.BITBUCKET_USER,
      token = vim.env.BITBUCKET_TOKEN,
      cache_ttl = 300, -- Set to 0 to disable caching.
    },

    ---@type AtlasJiraConfig
    jira = {
      base_url = "https://your-site.atlassian.net",
      email = "you@example.com", -- Required for basic authentication only.
      --- See: https://support.atlassian.com/atlassian-account/docs/manage-api-tokens-for-your-atlassian-account/
      token = "your_jira_api_token",
      auth_method = "basic", -- "basic" or "bearer", defaults to "basic". If using bearer, set `token` to your API token.
      api_type = "cloud", -- either "cloud" or "server", defaults to "cloud". Cloud API is v3, server API is v2
      cache_ttl = 300, -- Set to 0 to disable caching.
    },
  },

  -- See Pulls Configuration below.
  pulls = { },

  -- See Issue Configuration below.
  issues = { },
}
```

<details>
<summary><strong>Statusline</strong></summary>

Atlas comes with its own statusline for key hints, loading progress, and notifications. Keeping it enabled is recommended because most interaction and feedback goes through it.

If you use lualine, disable its statusline for Atlas buffers so it does not replace the Atlas statusline:

```lua
require("lualine").setup({
  options = {
    disabled_filetypes = {
      statusline = { "atlas" },
      winbar = {},
    },
  },
})
```

At some point there will probably an extension for lualine.

</details>

## Commands

- `:Atlas` - Pick a command
- `:Atlas pulls [provider]` - Open a pull-request provider dashboard
- `:Atlas issues [provider]` - Open an issue provider dashboard
- `:Atlas review [pull-request-url]` - Review a pull request with the configured diff viewer
- `:Atlas diff <target>` - Open a Git range or pull request in native AtlasDiff; a target is required
- `:Atlas pipelines [target|.]` - Open pipelines by branch name, PR URL or number, or build URL; `.` uses the current branch
- `:Atlas create [pr|issue]` - Create a pull request or issue
- `:Atlas search [provider]` - Search configured pull-request and issue providers
- `:Atlas open [target|.]` - Open a provider URL, Jira key, a PR/issue number in the current repository, or the current repository
- `:Atlas browse [repository URL|.] [page]` - Open the repository browser, e.g. `:Atlas browse . branches`
- `:Atlas notes [target]` - Inspect local review notes
- `:Atlas clear [cache|notes|stars]` - Clear all Atlas data or only cached data and cloned repositories, local review notes, or starred items
- `:Atlas logs` - Toggle Atlas logs

## Pulls

Use `:Atlas pulls [provider]` to browse and manage pull requests from GitHub, Bitbucket, and GitLab.
Shared authentication and endpoints are configured in the top-level `providers` table.

### Pulls Configuration

```lua
pulls = {
  delete_notes = false, -- Delete local PR notes after approval or merge.
  default_merge_method = "merge", -- "merge" or "squash".
  default_delete_branch = false,
  git_transport = "https", -- "https" or "ssh" for Atlas-managed Git remotes.

  -- Replaces the built-in Conventional Comments templates.
  comment_templates = {
    insert_mode = true, -- Enter Insert mode after applying a template.
    items = {
      { label = "Suggestion", text = "suggestion: " },
      { label = "Issue", text = "issue: " },
      { label = "Nitpick", text = "nitpick: " },
    },
  },

  diff = {
    -- Any command that accepts explicit <base>...<head> Git revisions.
    open_cmd = "AtlasDiff", -- default; for example "DiffviewOpen" or "CodeDiff".
    comment_display = "virtual_lines", -- "virtual_lines" or compact "virtual_text" hints.
    review_panel = {
      hidden = true, -- Set false to show the review panel when a diff opens.
      height = 10,
    },

    -- AtlasDiff options; external viewers use their own configuration.
    layout = "inline", -- "inline" or "side-by-side".
    compact = true, -- Start with only changed hunks and surrounding context visible.
    compact_context_lines = 3, -- Context lines shown around hunks in compact mode.
    lsp = {
      -- Back the new side of the diff with a detached worktree at the PR head so it is made of
      -- real files and your language servers attach to it (AtlasDiff only). Off by default.
      enabled = false,
      -- Defaults to `stdpath("cache")/atlas/worktrees/<repo>/pr-<id>` (or `<repo>/<sha>` without a PR).
      -- May be an absolute path, or a function receiving
      -- { repo_root, repo_full_name, pr_id, head_sha, default } that returns a path or nil.
      dir = nil,
      -- Directories symlinked from your checkout into the worktree so servers can resolve
      -- dependencies. These are the same directories on disk, not copies.
      link = {}, -- e.g. { "node_modules", ".venv" }
    },
    explorer = {
      grouped = true, -- Group changed files by directory.
      hidden = false,
      show_commits = false, -- Set true to show commits below changed files initially.
      width = 40,
      initial_focus = "explorer", -- "explorer" or "diff".
      preview = false, -- Show a file as soon as the explorer cursor moves onto it.
      ignore = { ".git/**", ".jj/**" },
    },
  },
  repo_config = {
    -- Maps `namespace/repo` to local paths. Used for checkout, diffs, and custom actions.
    paths = {
      ["your-workspace/*"] = "~/code/repos/*",
      ["your-workspace/atlas"] = "~/code/atlas",
      ["group/subgroup/*"] = "~/code/subgroup/*",
    },
    settings = {
      ["your-workspace/atlas"] = {
        readme = "README.md", -- optional, defaults to README.md
        pr_template = ".github/pull_request_template.md", -- optional, defaults to .github/pull_request_template.md
      },
    },
  },
  custom_actions = {}, -- See :help atlas-custom-actions.
},
```

<a id="github"></a>

<details>
<summary><strong>GitHub</strong></summary>

[Full configuration](https://github.com/emrearmagan/atlas.nvim/blob/main/lua/atlas/pulls/providers/github/config.lua)

```lua
pulls = {
  ---@type AtlasGitHubPullsConfig
  github = {
    ---@type AtlasGitHubViewConfig[]
    views = {
      {
        name = "My PRs",
        key = "1",
        layout = "plain", -- "compact", "grouped", or "plain"
        -- current_repo = true, -- Limit this view to the local repository.
        search = "author:@me sort:updated-desc",
      },
      {
        name = "Team",
        key = "2",
        layout = "compact",
        search = "org:your-org sort:updated-desc",
      },
      {
        name = "Repo",
        key = "3",
        layout = "grouped",
        search = "repo:your-org/your-repo",
      },
    },

    bookmarks = {
      key   = "S",      -- default
      label = "Search", -- default
      items = {
        ["Drafts"]           = "is:pr is:draft author:@me",
        ["Recently merged"]  = "is:pr is:merged author:@me sort:updated-desc",
        ["Review requested"] = "is:pr is:open review-requested:@me",
      },
    },
  },
},
```

<img alt="GitHub pull requests" src="https://github.com/user-attachments/assets/e18fbbb4-1b93-4059-8b80-0b6ebb7a55c6">

</details>

<a id="bitbucket"></a>

<details>
<summary><strong>Bitbucket</strong></summary>

[Full configuration](https://github.com/emrearmagan/atlas.nvim/blob/main/lua/atlas/pulls/providers/bitbucket/config.lua)

```lua
pulls = {
  ---@type AtlasBitbucketPullsConfig
  bitbucket = {
    ---@type AtlasBitbucketViewConfig[]
    views = {
      {
        name = "Me",
        key = "M",
        layout = "compact", -- "compact", "grouped", or "plain"
        -- current_repo = true, -- Remove repo:/project: targets from search when enabled.
        -- https://developer.atlassian.com/cloud/bitbucket/rest/#filter-and-sort-api-objects
        search = 'repo:your-workspace/standalone-repo project:your-workspace/CORE author.nickname = "your-name"',
      },
      {
        name = "Team",
        key = "1",
        layout = "grouped",
        search = 'project:your-workspace/TEAM destination.branch.name = "main"',
      },
    },

    bookmarks = {
      key   = "S",      -- default
      label = "Search", -- default
      items = {
        ["Atlas"] = {
          layout = "grouped",
          search = 'repo:your-workspace/atlas project:your-workspace/ATLAS title ~ "atlas"',
        },
      },
    },
  },
},
```

<img alt="Bitbucket pull requests" src="https://github.com/user-attachments/assets/d2a9c7cd-6aa5-46dc-bd04-5fd760a9269d">

</details>

<a id="gitlab"></a>

<details>
<summary><strong>GitLab</strong></summary>

[Full configuration](https://github.com/emrearmagan/atlas.nvim/blob/main/lua/atlas/pulls/providers/gitlab/config.lua)

```lua
pulls = {
  ---@type AtlasGitLabPullsConfig
  gitlab = {
    ---@type AtlasGitLabPullsViewConfig[]
    views = {
      {
        name = "Assigned",
        key = "1",
        layout = "grouped", -- "compact", "grouped", or "plain"
        scope = "assigned_to_me",
        -- current_repo = true, -- Limit this view to the local repository.
      },
      {
        name = "Reviewing",
        key = "3",
        scope = "reviews_for_me",
      },
      -- Single project
      {
        name = "GitLab",
        key = "G",
        project = "gitlab-org/gitlab",
        extra_params = { target_branch = "main" },
      },
      -- Whole group, all projects under it
      {
        name = "GitLab Org",
        key = "O",
        group = "gitlab-org",
      },
    },

    bookmarks = {
      key   = "S",      -- default
      label = "Search", -- default
      items = {
        ["Reviewing"]    = { scope = "reviews_for_me" },
        ["Created by me"] = { scope = "all", author_username = "me" },
      },
    },
  },
},
```

<img alt="GitLab pull requests" src="https://github.com/user-attachments/assets/6b3ea556-68b8-411e-ae2b-464a28071f61">

</details>

## Issues

Use `:Atlas issues [provider]` to browse and manage Jira, GitHub, and GitLab issues.
Shared authentication and endpoints are configured in the top-level `providers` table.

### Issue Configuration

```lua
issues = {
  with_relationships = true, -- Fetch parent/subissue relationships for plain issue tree views.
  custom_actions = {}, -- See :help atlas-custom-actions.
}
```

<a id="jira"></a>

<details>
<summary><strong>Jira</strong></summary>

> [!IMPORTANT]
> The markdown editor for issue descriptions and comments is still experimental and may not work perfectly in all cases. You can toggle between markdown and ADF view in the overview tab to see the raw ADF content and how it translates to markdown. If you encounter any issues with the markdown editor, please open an issue with details.

[Full configuration](https://github.com/emrearmagan/atlas.nvim/blob/main/lua/atlas/issues/providers/jira/config.lua)

```lua
issues = {
  ---@type AtlasJiraIssuesConfig
  jira = {
    ---@type AtlasJiraViewConfig[]
    views = {
      {
        name = "My Board",
        key = "M",
        layout = "plain",
        jql = "project = KAN AND assignee = currentUser() ORDER BY updated DESC",
      },
      {
        name = "Team Board",
        key = "T",
        layout = "compact",
        jql = "project = KAN ORDER BY updated DESC",
      },
    },

    bookmarks = {
      key   = "J",   -- default
      label = "JQL", -- default
      items = {
        ["Backlog"]     = "project = KAN AND statusCategory != Done AND (sprint IS EMPTY OR sprint NOT IN openSprints()) ORDER BY Rank ASC",
        ["Next sprint"] = "project = KAN AND sprint in futureSprints() ORDER BY Rank ASC",
        ["My open"]     = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC",
      },
    },

    project_config = {
      -- The Jira custom field ID used for story points. Defaults to "customfield_10016".
      story_points_field = "customfield_10016",
      -- Override issue type styles by name (case-insensitive).
      issue_types = {
        bug = { icon = "" },
        maintenance = { icon = "", hl_group = "AtlasTextWarning" },
        infrastructure = { icon = "󰒋", hl_group = "AtlasLogInfo" },
      },
      -- Override icons by status name or category.
      status_icons = {
        new = "●",
        indeterminate = "",
        done = "",
        ["In Review"] = "",
      },

      -- Custom fields to display per project; replace KAN with your project key.
      KAN = {
        customfield_10003 = {
          name = "Approvers",
          format = function(value)
            if type(value) ~= "table" or #value == 0 then
              return nil -- nil hides the field
            end
            return table.concat(value, ", ")
          end,
          hl_group = "AtlasChipActive",
          display = "chip", -- "chip" or "table"
        },
      },
    },
  },
},
```

<img alt="Jira issues" src="https://github.com/user-attachments/assets/9cbf7ce9-b16f-409d-a8c0-b499af99c127">

</details>

<a id="github-issues"></a>

<details>
<summary><strong>GitHub Issues</strong></summary>

[Full configuration](https://github.com/emrearmagan/atlas.nvim/blob/main/lua/atlas/issues/providers/github/config.lua)

```lua
issues = {
  ---@type AtlasGitHubIssuesConfig
  github = {
    ---@type AtlasGitHubIssuesViewConfig[]
    views = {
      {
        name = "Assigned",
        key = "1",
        layout = "plain",
        -- current_repo = true, -- Limit this view to the local repository.
        search = "assignee:@me is:open",
      },
      {
        name = "Created",
        key = "2",
        layout = "compact",
        search = "author:@me is:open",
      },
      {
        name = "Mentions",
        key = "3",
        layout = "plain",
        search = "mentions:@me is:open",
      },
    },

    bookmarks = {
      key   = "S",      -- default
      label = "Search", -- default
      items = {
        ["Bugs"]            = "is:issue is:open label:bug",
        ["Recently closed"] = "is:issue is:closed author:@me sort:updated-desc",
      },
    },
  },
},
```

</details>

<a id="gitlab-issues"></a>

<details>
<summary><strong>GitLab Issues</strong></summary>

[Full configuration](https://github.com/emrearmagan/atlas.nvim/blob/main/lua/atlas/issues/providers/gitlab/config.lua)

```lua
issues = {
  ---@type AtlasGitLabIssuesConfig
  gitlab = {
    ---@type AtlasGitLabIssuesViewConfig[]
    views = {
      {
        name = "Assigned",
        key = "1",
        scope = "assigned_to_me",
        state = "opened",
        -- current_repo = true, -- Limit this view to the local repository.
      },
      {
        name = "Created",
        key = "2",
        scope = "created_by_me",
        state = "opened",
      },
      {
        name = "All open",
        key = "3",
        scope = "all",
        state = "opened",
        -- Pass additional API filters via extra_params.
        extra_params = { ["not[labels]"] = "wontfix" },
      },
    },

    bookmarks = {
      key   = "S",      -- default
      label = "Search", -- default
      items = {
        ["No labels"] = { scope = "all", state = "opened",
                          extra_params = { ["not[labels]"] = "*" } },
        ["Closed"]    = { scope = "created_by_me", state = "closed" },
      },
    },
  },
},
```

</details>

## Events

Atlas emits these `User` events after the corresponding cleanup or setup has completed:

- `AtlasUIClosed` for the main pulls/issues dashboard.
- `AtlasDiffOpened` and `AtlasDiffClosed` for the native AtlasDiff view.
- `AtlasReviewAttached` and `AtlasReviewDetached` for Atlas review overlays in AtlasDiff, CodeDiff, and Diffview.

## Keymaps

Set an action to `false` to disable it, or set it to a list to add aliases.

```lua
keymaps = {
  ui = {
    help = "g?", -- { "g?", "<leader>?" } would add aliases
    close = "q", -- false would disable it
    next_item = "j",
    previous_item = "k",
    first_item = "gg",
    last_item = "G",
    select = "<CR>",
    submit = "<C-s>",
    delete = "dd",
    comments = {
      add = { "a", "i" },
      reply = "c",
      edit = "e",
      react = "gr",
    },
    toggle_panel = "p",
    toggle_fold = "za",
    toggle_all_folds = "zA",
    toggle_description_mode = "<leader>m",
    previous_panel_tab = "<S-Tab>",
    next_panel_tab = "<Tab>",
    notifications = {
      open = "N",
      mark_read = "r",
      mark_done = "d",
    },
    toggle_subscription = "gS",
    toggle_star = "*",
    refresh = "r",
    refresh_view = "R",
    next_page = "]p",
    previous_page = "[p",
    open_actions = "A",
    open_in_browser = "gx",
    open_references = "gl",
    copy_id = "y",
    copy_url = "Y",
    show_details = "K",
    search = "?",
  },
  picker = {
    next_item = { "<Down>", "<C-n>", "<C-j>" },
    previous_item = { "<Up>", "<C-p>", "<C-k>" },
    select = { "<CR>", "<C-s>" },
    toggle = "<Tab>",
    close = { "q", "<Esc>" },
  },
  issues = {
    transition_issue = "gs",
    change_assignee = "ga",
    change_reporter = "gr",
    edit_issue = "ge",
    edit_search = "i",
    create_issue = "c",
  },
  pulls = {
    open_diff = "gd",
    checkout = "gc",
    external_help = "gA", -- Atlas help in external diff viewers
    open_repository = "o",
    toggle_repo_issue_state = "t",
    edit_title = "T",
    edit_description = "D",
    edit_search = "i",
    pipelines = {
      next_job = { "]j", "<Tab>" },
      previous_job = { "[j", "<S-Tab>" },
      show_history = "gH",
      toggle_raw_logs = "gL",
      toggle_auto_refresh = "gR",
    },
    review = {
      open_item = "<CR>", -- Open the selected file, review item, or inline comment/note.
      show_details = "K",
      approve = "<leader>ga",
      request_changes = "<leader>gr",
      submit_review = "<leader>gs",
      add_task = "<leader>t",
      find_file = "<leader>ff",
      comment_templates = "gT",
      explorer = {
        toggle_explorer = "<leader>b",
        find_file = { "f", "<leader>ff" },
        next_file = { "]f", "<Tab>" },
        previous_file = { "[f", "<S-Tab>" },
        next_unreviewed_file = "]u",
        previous_unreviewed_file = "[u",
        toggle_grouping = "T",
        toggle_file_reviewed = "-",
        toggle_commits = "gC",
      },
      diff = {
        toggle_layout = "t",
        toggle_compact = "gc",
        next_hunk = "]h",
        previous_hunk = "[h",
        toggle_review_panel = "gR",
        toggle_detail_panel = "gD",
        toggle_comments = "gH",
        next_comment = "]c",
        previous_comment = "[c",
        next_note = "]n",
        previous_note = "[n",
        add_comment = "c",
        submit_comment = "C",
        add_suggestion = "s",
        submit_suggestion = "S",
        add_note = "<leader>n",
        toggle_resolved = "x",
      },
    },
    filters = {
      open = "gpo",
      merged = "gpm",
      declined = "gpd",
    },
  },
},
```

### Custom Keymaps

You can add custom keymaps to run Atlas actions, commands, or your own Lua functions.

```lua
local actions = require("atlas.pulls.actions")

keymaps = {
  pulls = {
    custom = {
      {
        key = "gP",
        desc = "Open pipelines",
        callback = function(context, done)
          actions.run("open_pipelines", context, done)
        end,
      },
    },
  },
  issues = {
    custom = {
      {
        key = "<leader>as",
        desc = "Atlas search",
        callback = function()
          vim.cmd("Atlas search")
        end,
      },
    },
  },
}
```

## Credits

Thank you to everyone who has contributed to Atlas! ❤️

<a href="https://github.com/emrearmagan/atlas.nvim/graphs/contributors">
  <img src="https://contrib.rocks/image?columns=25&max=10000&repo=emrearmagan/atlas.nvim" alt="Atlas contributors">
</a>

## Contributing

Contributions are welcome! If you'd like to contribute, please open an [issue](https://github.com/emrearmagan/atlas.nvim/issues) or [pull request](https://github.com/emrearmagan/atlas.nvim/pulls) on GitHub. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT License - see [LICENSE](LICENSE) for details.
