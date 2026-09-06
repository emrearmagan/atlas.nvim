[![Neovim](https://img.shields.io/badge/Neovim-0.10+-blue.svg)](https://neovim.io/)
[![Version](https://img.shields.io/github/v/tag/emrearmagan/atlas.nvim.svg)](https://github.com/emrearmagan/atlas.nvim/tags)
[![CI](https://github.com/emrearmagan/atlas.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/emrearmagan/atlas.nvim/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/emrearmagan/atlas.nvim?style=flat-square&color=blue)](LICENSE)

# Atlas.nvim

Review pull requests and manage issues across GitHub, GitLab, Bitbucket, Jira and Shortcut without leaving your editor.

<p>
  <img alt="GitHub" src="https://img.shields.io/badge/GitHub-181717?style=flat-square&logo=github&logoColor=white">
  <img alt="Bitbucket" src="https://img.shields.io/badge/Bitbucket-0052CC?style=flat-square&logo=bitbucket&logoColor=white">
  <img alt="GitLab" src="https://img.shields.io/badge/GitLab-FC6D26?style=flat-square&logo=gitlab&logoColor=white">
  <img alt="Jira" src="https://img.shields.io/badge/Jira-0052CC?style=flat-square&logo=jira&logoColor=white">
  <img alt="Shortcut" src="https://img.shields.io/badge/Shortcut-494BCB?style=flat-square&logo=shortcut&logoColor=white">
</p>

<img alt="Atlas UI" src="https://github.com/user-attachments/assets/de6459f9-f123-40a6-acbd-097a17e7ae86" />

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
    "MeanderingProgrammer/render-markdown.nvim", -- optional but recommended
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

### Requirements

- Neovim: `0.10+`
- `git` and `curl` on `$PATH`
- Jira: Jira Cloud REST API v3 (`*.atlassian.net`) or Jira Server REST API v2
- Bitbucket: Bitbucket Cloud REST API 2.0 (`api.bitbucket.org`)
- GitHub: GitHub CLI (`gh`) authenticated with `gh auth login`
- GitLab: GitLab REST API v4 (`gitlab.com` or self-hosted), Personal Access Token with `api` scope
- Shortcut: Shortcut REST API v3 and a [personal API token](https://app.shortcut.com/settings/account/api-tokens)

> [!tip]
> It's a good idea to run `:checkhealth atlas` to see if everything is set up correctly.

## Features

### Review Pull Requests

<img alt="AtlasDiff" src="https://github.com/user-attachments/assets/7280373a-f6e9-4847-be64-89e245d461cd">

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

### Also included

<details>
<summary><strong>Pipelines</strong> - View jobs and logs, retry failures, or cancel running work</summary>

<p align="center">
  <img width="85%" alt="View pipelines" src="https://github.com/user-attachments/assets/c625c4e8-b1ad-4772-b46b-24718ba6fbb7">
</p>

View pipelines and their jobs, inspect their status, and read job logs directly in Atlas. Retry failed pipelines or jobs and cancel work that is still running.

</details>

<details>
<summary><strong>Custom actions</strong> - Run project-specific actions for pull requests and issues</summary>

<p align="center">
  <img width="85%" alt="Atlas custom action" src="https://github.com/user-attachments/assets/a8ca355b-09e2-428c-b3fb-3280fd161110">
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
      confirmation = true,
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
  <img width="50%" alt="Create pull request" src="https://github.com/user-attachments/assets/d6335c66-35f7-4495-b83a-53819d7ec7d5"><img width="50%" alt="Create issue" src="https://github.com/user-attachments/assets/8f3b06d8-763d-4e0f-ab93-9c3754065ca3">
</p>

Use `:Atlas create [pr|issue]` to create a pull request from the current branch or a new issue. For pull requests, Atlas can fill the description from your template or commits.

</details>

<details>
<summary><strong>Notifications</strong> - Read and clear GitHub and GitLab notifications</summary>

<p align="center">
  <img width="85%" alt="Notifications" src="https://github.com/user-attachments/assets/117b5ad7-3840-4487-bd91-f2f9bf213428">
</p>

Open GitHub and GitLab notifications inside Atlas, refresh them, open the related item, and mark notifications as read or done without leaving Neovim.

</details>

<details>
<summary><strong>Bookmarks</strong> - Save searches and star items locally</summary>

<p align="center">
  <img width="85%" alt="Bookmarks" src="https://github.com/user-attachments/assets/f008d6af-dfc6-4b65-8af1-94cd6ce9fc99">
</p>

Save searches as bookmarks, or press `*` to star a pull request or issue. Both appear alongside your configured views.

</details>

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

    ---@type AtlasShortcutConfig
    shortcut = {
      -- Create a token at https://app.shortcut.com/settings/account/api-tokens
      token = vim.env.SHORTCUT_TOKEN,
      cache_ttl = 300, -- Set to 0 to disable caching.
    },
  },

  -- See Pulls Configuration below.
  pulls = { },

  -- See Issue Configuration below.
  issues = { },
}
```

### Statusline

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

## Commands

- `:Atlas` - Pick a command
- `:Atlas pulls [provider]` - Open a pull-request provider dashboard
- `:Atlas issues [provider]` - Open an issue provider dashboard
- `:Atlas review [pull-request-url]` - Review a pull request with the configured diff viewer
- `:Atlas diff [target]` - Open a Git range or pull request in native AtlasDiff
- `:Atlas create [pr|issue]` - Create a pull request or issue
- `:Atlas search [provider]` - Search configured pull-request and issue providers
- `:Atlas open [target|.]` - Open a provider URL, Jira key, a PR/issue number in the current repository, or the current repository
- `:Atlas notes [target]` - Inspect local review notes
- `:Atlas clear [cache|notes|stars]` - Clear all Atlas data or only cached data and cloned repositories, local review notes, or starred items
- `:Atlas logs` - Toggle Atlas logs
- `:AtlasDiff <base>...<head>` - Open a Git range in native AtlasDiff directly
- `:AtlasDiff <pull-request-url>` - Open a pull request in native AtlasDiff directly

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
    show_review_panel = false, -- Set true to show the review panel when a diff opens.
    comment_display = "virtual_lines", -- "virtual_lines" or compact "virtual_text" hints.
    review_panel = {
      height = 10,
    },

    -- AtlasDiff options; external viewers use their own configuration.
    layout = "inline", -- "inline" or "side-by-side".
    compact = true, -- Start with only changed hunks and surrounding context visible.
    compact_context_lines = 3, -- Context lines shown around hunks in compact mode.
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
    -- Maps `workspace/repo` to local paths. Used for checkout, diffs, and custom actions.
    paths = {
      ["your-workspace/*"] = "~/code/repos/*",
      ["your-workspace/atlas"] = "~/code/atlas",
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

<img alt="GitHub pull requests" src="https://github.com/user-attachments/assets/8b570bb3-d073-4ab0-99fc-2d9179e173cd">

</details>

<a id="bitbucket"></a>

<details>
<summary><strong>Bitbucket</strong></summary>

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

<img alt="Bitbucket pull requests" src="https://github.com/user-attachments/assets/bcdd0c9c-e15f-4e82-81fd-cde38aa68a2d">

</details>

<a id="gitlab"></a>

<details>
<summary><strong>GitLab</strong></summary>

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

<img alt="GitLab pull requests" src="https://github.com/user-attachments/assets/128fe916-e733-4abb-9c5c-5244684f3c41">

</details>

## Issues

Use `:Atlas issues [provider]` to browse and manage Jira, GitHub, and GitLab issues and Shortcut Stories.
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
      issue_types = {
        ["Maintenance"] = { icon = "", hl_group = "AtlasTextWarning" },
        ["Infrastructure"] = { icon = "󰒋", hl_group = "AtlasLogInfo" },
      },

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

<img alt="Jira issues" src="https://github.com/user-attachments/assets/4cb40f1f-0b18-4fb1-82ae-6bc57fc8a7c5">

</details>

<a id="github-issues"></a>

<details>
<summary><strong>GitHub Issues</strong></summary>

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
        -- Anything not covered by the explicit fields below can be passed via `extra_params`.
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

<a id="shortcut-issues"></a>

<details>
<summary><strong>Shortcut Stories</strong></summary>

Shortcut uses its fixed REST API v3 endpoint. Create a token in [Shortcut API token settings](https://app.shortcut.com/settings/account/api-tokens), store it in an environment variable, and configure the provider separately from its issue views:

```lua
providers = {
  ---@type AtlasShortcutConfig
  shortcut = {
    token = vim.env.SHORTCUT_TOKEN,
    cache_ttl = 300, -- Set to 0 to disable caching.
  },
},

issues = {
  ---@type AtlasShortcutIssuesConfig
  shortcut = {
    ---@type AtlasShortcutIssuesViewConfig[]
    views = {
      {
        name = "Mine",
        key = "1",
        layout = "plain",
        -- https://www.shortcut.com/help/fields-and-features/search-operators/
        search = "owner:johnsmith !is:done !is:archived",
      },
      {
        name = "Bugs",
        key = "2",
        layout = "compact",
        search = "type:bug !is:done !is:archived",
      },
    },

    bookmarks = {
      key   = "S",      -- default
      label = "Search", -- default
      items = {
        ["Open bugs"]    = "type:bug !is:done !is:archived",
        ["Needs review"] = 'label:"needs-review" !is:done',
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
    create_issue = "c",
    toggle_task = "x",
    toggle_description_mode = "m",
  },
  pulls = {
    open_diff = "gd",
    checkout = "gc",
    external_help = "gA", -- Atlas help in external diff viewers
    toggle_repo_panel = "o",
    toggle_repo_issue_state = "t",
    edit_title = "T",
    edit_description = "D",
    review = {
      focus_item = "gd",
      approve = "ga",
      request_changes = "gr",
      submit_review = "gs",
      add_task = "<leader>t",
      comment_templates = "gT",
      find_file = "<leader>ff",
      explorer = {
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

## Credits

Thank you to everyone who has contributed to Atlas! ❤️

<a href="https://github.com/emrearmagan/atlas.nvim/graphs/contributors">
  <img src="https://contrib.rocks/image?columns=25&max=10000&repo=emrearmagan/atlas.nvim" alt="Atlas contributors">
</a>

## Contributing

Contributions are welcome! If you'd like to contribute, please open an [issue](https://github.com/emrearmagan/atlas.nvim/issues) or [pull request](https://github.com/emrearmagan/atlas.nvim/pulls) on GitHub. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT License - see [LICENSE](LICENSE) for details.
