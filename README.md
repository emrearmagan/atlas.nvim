[![Neovim](https://img.shields.io/badge/Neovim-0.10+-blue.svg)](https://neovim.io/)
[![Version](https://img.shields.io/github/v/tag/emrearmagan/atlas.nvim.svg)](https://github.com/emrearmagan/atlas.nvim/tags)
[![Tests](https://github.com/emrearmagan/atlas.nvim/actions/workflows/main.yml/badge.svg)](https://github.com/emrearmagan/atlas.nvim/actions/workflows/main.yml)
[![License](https://img.shields.io/github/license/emrearmagan/atlas.nvim?style=flat-square&color=blue)](LICENSE)

# Atlas.nvim

A Neovim plugin for managing GitHub/Bitbucket/GitLab PRs and Jira/GitHub/GitLab issues without leaving your editor.

> [!CAUTION]
> **Still in early development, will have breaking changes!**

<p>
  <img alt="GitHub" src="https://img.shields.io/badge/GitHub-181717?style=flat-square&logo=github&logoColor=white">
  <img alt="Bitbucket" src="https://img.shields.io/badge/Bitbucket-0052CC?style=flat-square&logo=bitbucket&logoColor=white">
  <img alt="GitLab" src="https://img.shields.io/badge/GitLab-FC6D26?style=flat-square&logo=gitlab&logoColor=white">
  <img alt="Jira" src="https://img.shields.io/badge/Jira-0052CC?style=flat-square&logo=jira&logoColor=white">
</p>

<p align="center">
  <img width="49%" alt="Atlas UI" src="https://github.com/user-attachments/assets/caa30d3c-6883-4f2e-bc12-81bb2127f798">
  <img width="49%" alt="AtlasDiff" src="https://github.com/user-attachments/assets/caa30d3c-6883-4f2e-bc12-81bb2127f798">
</p>

## Table of Contents

- [Installation](#installation)
  - [Using lazy.nvim](#using-lazynvim)
  - [Using packer.nvim](#using-packernvim)
- [Requirements](#requirements)
- [Commands](#commands)
- [Pulls](#pulls)
  - [Configuration](#configuration)
    - [GitHub](#github)
    - [Bitbucket](#bitbucket)
    - [GitLab](#gitlab)
  - [Review Pulls](#review-pulls)
  - [Create Pulls](#create-pulls)
- [Issues](#issues)
  - [Configuration](#configuration)
    - [Jira](#jira)
    - [GitHub](#github-issues)
    - [GitLab](#gitlab-issues)
  - [Create Issues](#create-issues)
- [Keymaps](#keymaps)

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "emrearmagan/atlas.nvim",
  dependencies = {
    "nvim-tree/nvim-web-devicons", -- optional but recommended
    "MeanderingProgrammer/render-markdown.nvim", -- optional but recommended
    "esmuellert/codediff.nvim", -- optional (PullRequest diff)
    "sindrets/diffview.nvim", -- optional (PullRequest diff - alternative)
  },
  opts = {
    pulls = {
      providers = {
        ---@type AtlasBitbucketConfig
        bitbucket = {}, -- See configuration below
        ---@type AtlasGitHubConfig
        github = {},    -- See configuration below
        ---@type AtlasGitLabPullsConfig
        gitlab = {},    -- See configuration below
      },
    },
    issues = {
      providers = {
        ---@type AtlasJiraIssuesConfig
        jira = {},   -- See configuration below
        ---@type AtlasGitHubIssuesConfig
        github = {}, -- See configuration below
        ---@type AtlasGitLabIssuesConfig
        gitlab = {}, -- See configuration below
      },
    },
  },
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "emrearmagan/atlas.nvim",
  config = function()
    require("atlas").setup({
      pulls = {
        providers = {
          ---@type AtlasBitbucketConfig
          bitbucket = {}, -- See configuration below
          ---@type AtlasGitHubConfig
          github = {},    -- See configuration below
          ---@type AtlasGitLabPullsConfig
          gitlab = {},    -- See configuration below
        },
      },
      issues = {
        providers = {
          ---@type AtlasJiraIssuesConfig
          jira = {},   -- See configuration below
          ---@type AtlasGitHubIssuesConfig
          github = {}, -- See configuration below
          ---@type AtlasGitLabIssuesConfig
          gitlab = {}, -- See configuration below
        },
      },
    })
  end
}
```

> [!tip]
> It's a good idea to run `:checkhealth atlas` to see if everything is set up correctly.

## Requirements

- Neovim: `0.10+`
- `git` and `curl` on `$PATH`
- Jira: Jira Cloud REST API v3 (`*.atlassian.net`) or Jira Server REST API v2
- Bitbucket: Bitbucket Cloud REST API 2.0 (`api.bitbucket.org`)
- GitHub: GitHub CLI (`gh`) authenticated with `gh auth login`
- GitLab: GitLab REST API v4 (`gitlab.com` or self-hosted), Personal Access Token with `api` scope

> [!NOTE]
> I have only tested this with my personal and work accounts. If you encounter any issues, please feel free to open an issue.
> See: https://support.atlassian.com/atlassian-account/docs/manage-api-tokens-for-your-atlassian-account/
>
> I have also not tested with self-hosted GitLab instances, but in theory it should work. If it doesn't, feel free to open an issue. If it does work, please remove this note :)

## Commands

- `:AtlasIssues [provider]` - Open Atlas issues domain
- `:AtlasPulls [provider]` - Open Atlas pulls domain
- `:AtlasDiff <base>...<head>` - Open the native diff viewer
- `:AtlasNotes` - Inspect local review notes across pull requests
- `:AtlasCreatePR` - Create a pull request from the current branch
- `:AtlasCreateIssue` - Create an issue (GitHub / GitLab / Jira)
- `:AtlasSearch [provider]` - Pick a configured provider and prompt its search
- `:AtlasOpen <target>` - Open a provider URL, Jira key, repository reference, or PR/issue number
- `:AtlasClearCache` - Clear Atlas disk and memory cache
- `:AtlasLogs` - Toggle Atlas logs

## Pulls

Use `:AtlasPulls [provider]` to browse and manage pull requests from GitHub, Bitbucket, and GitLab.

- [x] Multiple configurable views, provider search, and bookmarks
- [x] Repository overview, branches, tags, and GitHub/GitLab repository issues
- [x] Pull request tabs for overview, activity/conversation, review, and commits
- [x] Pull request actions such as merge, approve, request changes, draft/ready, and reviewer management
- [x] Comment workflows including create, reply, edit, delete, reactions, resolve, and reopen
- [x] Pending comments, inline threads, provider tasks, and GitHub checklists
- [x] Build/CI status and merge checks
- [x] Commits and diffstat summaries
- [x] Checkout pull request branches
- [x] Add custom actions to pull requests
- [x] Open pull request diffs in AtlasDiff, CodeDiff, or Diffview
- [x] Native reviews with inline threads, provider tasks/checklists, and private local notes
- [x] Switch between open, merged, and closed pull requests
- [x] Subscribe or unsubscribe to pull requests
- [x] View and manage provider notifications
- [x] Create pull requests with `:AtlasCreatePR`, including draft state, templates, commits, diffstat, and reviewer selection where supported
- [ ] Complete pagination across providers and API results

### Configuration

```lua
pulls = {
  diff = {
    -- Command must support explicit <base>...<head> Git revisions.
    open_cmd = "AtlasDiff", -- default; can be replaced with "DiffviewOpen" / "CodeDiff".
    layout = "side-by-side", -- "side-by-side" or "inline" for AtlasDiff.
    compact = true, -- Start with only changed hunks and surrounding context visible.
    explorer = {
      grouped = true, -- Group changed files by directory.
      hidden = false,
      show_commits = true, -- Initially show commits below changed files.
      width = 40,
      initial_focus = "explorer", -- "explorer" or "diff".
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
  custom_actions = {}, -- See Custom Actions below.
},
```

#### GitHub

<details>
<summary><strong>Configuration</strong></summary>

```lua
pulls = {
  providers = {
    github = {
      cache_ttl = 300,

      ---@type AtlasGitHubViewConfig[]
      views = {
        {
          name = "My PRs",
          key = "1",
          layout = "plain",
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
          layout = "plain",
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
},
```

<img alt="GitHub pull requests" src="https://github.com/user-attachments/assets/caa30d3c-6883-4f2e-bc12-81bb2127f798">

</details>

#### Bitbucket

<details>
<summary><strong>Configuration</strong></summary>

```lua
pulls = {
  providers = {
    bitbucket = {
      user = vim.env.BITBUCKET_USER,
      token = vim.env.BITBUCKET_TOKEN,
      cache_ttl = 300,

      ---@type AtlasBitbucketViewConfig[]
      views = {
        {
          name = "Me",
          key = "M",
          layout = "compact",
          repos = {
            { workspace = "your-workspace", repo = "atlas" },
          },

          ---@param pr PullRequest
          ---@param ctx { user: PullsUser|nil }
          filter = function(pr, ctx)
            local user = ctx.user
            return pr.author and user and pr.author.id == user.id
          end,
        },
        {
          name = "Team",
          key = "1",
          layout = "plain", -- "compact" or "plain"
          repos = {
            { workspace = "your-workspace", repo = "atlas" },
            { workspace = "your-workspace", repo = "other-repo" },
          },
        },
      },
    },
  },
},
```

<img alt="Bitbucket pull requests" src="https://github.com/user-attachments/assets/06299ffc-b15b-4e2c-8f11-95a8ddde3b04">

</details>

#### GitLab

<details>
<summary><strong>Configuration</strong></summary>

Auth uses a [Personal Access Token](https://docs.gitlab.com/ee/user/profile/personal_access_tokens.html) with the `api` scope. Set `base_url` to `https://gitlab.com` or your self-hosted instance.

```lua
pulls = {
  providers = {
    gitlab = {
      base_url = "https://gitlab.com",
      token = vim.env.GITLAB_TOKEN,
      cache_ttl = 300,

      ---@type AtlasGitLabPullsViewConfig[]
      views = {
        {
          name = "Assigned",
          key = "1",
          scope = "assigned_to_me",
        },
        {
          name = "Reviewing",
          key = "3",
          scope = "all",
          extra_params = { reviewer_id = "Me" },
        },
        -- Single project
        {
          name = "GitLab",
          key = "G",
          project = "gitlab-org/gitlab",
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
          ["Reviewing"]    = { scope = "all", extra_params = { reviewer_id = "Me" } },
          ["Merged by me"] = { scope = "all", state = "merged", author_username = "me" },
        },
      },
    },
  },
},
```

<img alt="GitLab pull requests" src="https://github.com/user-attachments/assets/81b4023b-7f36-47cf-aeaf-28f9c1ebeb76">

</details>

#### Custom Actions

You can add custom PR actions under `pulls.custom_actions`.

<details>
<summary><strong>Example</strong></summary>

Context type:

```lua
---@class AtlasPullsCustomActionContext
---@field repo_path string|nil
---@field pr PullRequest
```

Example:

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
      id = "open_tmux_window",
      label = "Open repo in tmux window",
      confirmation = true, -- present a confirmation prompt before running the action
      ---@param pr PullRequest
      ---@param ctx AtlasPullsCustomActionContext
      ---@param done fun(ok: boolean|nil, message: string|nil)
      run = function(_, ctx, done)
        if not ctx.repo_path then
          done(false, "No repo path")
          return
        end

        vim.system({ "tmux", "new-window", "-c", ctx.repo_path }, { text = true }, function(res)
          vim.schedule(function()
            if res.code ~= 0 then
              done(false, "Failed to open tmux window")
              return
            end
            done(true, "Opened tmux window")
          end)
        end)
      end,
    },
  },
  providers = {
    ...,
  },
}
```

![CleanShot2026-03-31at20 08 06-ezgif com-video-to-gif-converter](https://github.com/user-attachments/assets/a8ca355b-09e2-428c-b3fb-3280fd161110)

</details>

### Review Pulls

Press the configured `pulls.open_diff` key (`gd` by default) on a pull request to start a review. 

<p align="center">
  <img alt="AtlasDiff review" src="https://github.com/user-attachments/assets/caa30d3c-6883-4f2e-bc12-81bb2127f798">
</p>

- See pending, resolved, and outdated provider threads at their diff locations.
- Review provider tasks and GitHub checklists alongside the comments they belong to.
- Add, reply to, edit, delete, resolve, or reopen comments when supported.

> [!NOTE]
> **Alternative viewers:** CodeDiff can display Atlas comment and task overlays, but the integration relies on CodeDiff internals and may break after upstream changes. I used it from my dotfiles for a while before moving it into Atlas. Diffview remains available as a plain diff viewer without Atlas review overlays since i dont use that plugin.

#### Local notes

Local notes let you leave something on a diff without posting it to the pull request. Each note is attached to a file and line and can be an `ISSUE`, `SUGGESTION`, `NOTE`, or `PRAISE`. If that line changes, Atlas shows the note as outdated. If the location no longer exists, Atlas removes it. `:AtlasNotes` lists your notes across all pull requests.

For scripts, use `bin/atlas-notes`. Notes added there appear in AtlasDiff and `:AtlasNotes`:

```sh
./bin/atlas-notes add \
  --target https://github.com/owner/repository/pull/123 \
  --file lua/review_queue.lua --line 19 \
  --head "$(git rev-parse HEAD)" \
  --type suggestion --body "Should this be a bool?"
```

### Create Pulls

Run `:AtlasCreatePR` on the branch you want to submit. The current branch is used as the source and the repository's default branch as the target. The latest commit supplies the initial title. A configured pull request template supplies the description; without one, Atlas builds it from the branch commits.

Before creating the pull request, you can change the target branch, reviewers, and draft state. The commits and diffstat are shown below the editor, and the diff can be previewed from there.

<p align="center">
  <img alt="Create pull request" src="https://github.com/user-attachments/assets/caa30d3c-6883-4f2e-bc12-81bb2127f798">
</p>

## Issues

Use `:AtlasIssues [provider]` to browse and manage Jira, GitHub, and GitLab issues.

- [x] Multiple configurable views, provider search, and bookmarks
- [x] Issue overview, conversation, and activity
- [x] Create GitHub, GitLab, and Jira issues with `:AtlasCreateIssue`
- [x] Edit issue descriptions and provider-specific fields
- [x] Comment workflows including create, reply, edit, delete, and reactions
- [x] Provider actions for status, assignees, reporters, labels, subscriptions, and deletion
- [x] Parent and subissue relationships
- [x] Jira JQL completion, custom fields, and Markdown/ADF descriptions
- [x] Reusable issue templates
- [x] Add custom actions to issues
- [x] View and manage provider notifications
- [ ] Save searches and filters from the UI

### Issue Configuration

```lua
issues = {
  max_results = 100,
  with_relationships = true, -- Fetch parent/subissue relationships for plain issue tree views.
  custom_actions = {}, -- See Custom Actions below.
}
```

#### Jira

> [!NOTE]
> If you're only looking for Jira support, check out https://github.com/letieu/jira.nvim. This plugin was the main inspiration for this project.
> Jira support is included here mainly because I wanted a single tool that works with both Atlassian products.

> [!IMPORTANT]
> The markdown editor for issue descriptions and comments is still experimental and may not work perfectly in all cases. You can toggle between markdown and ADF view in the overview tab to see the raw ADF content and how it translates to markdown. If you encounter any issues with the markdown editor, please open an issue with details.

<details>
<summary><strong>Configuration</strong></summary>

```lua
issues = {
  providers = {
    jira = {
      base_url = "https://your-site.atlassian.net",
      email = "you@example.com",
      --- See: https://support.atlassian.com/atlassian-account/docs/manage-api-tokens-for-your-atlassian-account/
      token = "your_jira_api_token",
      auth_method = "basic", -- "basic" or "bearer", defaults to "basic". If using bearer, set `token` to your API token.
      api_type = "cloud", -- either "cloud" or "server", defaults to "cloud". Cloud API is v3, server API is v2
      cache_ttl = 300,

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
    },
  },
},
```

<img alt="Edit/Create Issue" src="https://github.com/user-attachments/assets/76913fbf-1667-4f35-9962-d3c1b4619c7f">

<img alt="Jira issues" src="https://github.com/user-attachments/assets/23a15b90-283c-45e2-8964-02970ec3b21a">

</details>

#### GitHub Issues

<details>
<summary><strong>Configuration</strong></summary>

```lua
issues = {
  providers = {
    github = {
      cache_ttl = 300,

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
},
```

</details>

#### GitLab Issues

<details>
<summary><strong>Configuration</strong></summary>

Auth uses a [Personal Access Token](https://docs.gitlab.com/ee/user/profile/personal_access_tokens.html) with the `api` scope. Set `base_url` to `https://gitlab.com` or your self-hosted instance.

```lua
issues = {
  providers = {
    gitlab = {
      base_url = "https://gitlab.com",
      token = vim.env.GITLAB_TOKEN,
      cache_ttl = 300,

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
},
```

</details>

#### Custom Actions

You can add custom issue actions under `issues.custom_actions`.

<details>
<summary><strong>Example</strong></summary>

Context type:

```lua
---@class AtlasIssuesCustomActionContext
---@field issue Issue|nil
---@field user IssueUser|nil
```

Example:

```lua
issues = {
  custom_actions = {
    {
      id = "copy_branch_name",
      label = "Copy branch name",
      ---@param issue Issue
      ---@param ctx AtlasIssuesCustomActionContext
      ---@param done fun(ok: boolean|nil, message: string|nil)
      run = function(issue, ctx, done)
        local branch = string.format("%s/%s", issue.key, issue.summary:lower():gsub("%s+", "-"))
        vim.fn.setreg("+", branch)
        done(true, "Copied: " .. branch)
      end,
    },
  },
}
```

</details>

### Create Issues

`:AtlasCreateIssue` opens the creation flow for the configured issue providers. GitHub and GitLab use the current repository, while Jira uses the configured instance. The forms support Markdown descriptions and provider-specific fields such as labels, assignees, milestones, and Jira issue types.

GitHub, GitLab, and Jira can apply a saved Markdown template or save the current description as a new one. Templates are shared between providers and stored under Neovim's data directory.

<p align="center">
  <img alt="Create issue" src="https://github.com/user-attachments/assets/76913fbf-1667-4f35-9962-d3c1b4619c7f">
</p>

## Keymaps

Set an action to `false` to disable it, or set it to a list to add aliases.

```lua
keymaps = {
  ui = {
    help = "g?",
    close = "q", -- false would disable it
    toggle_panel = "p", -- { "p", "k" } would add aliases
    toggle_fold = "za",
    toggle_all_folds = "zA",
    previous_panel_tab = "<S-Tab>",
    next_panel_tab = "<Tab>",
    open_notifications = "N",
    notifications_mark_read = "r",
    notifications_mark_done = "d",
    notifications_refresh = "R",
    toggle_subscription = "gS",
    refresh = "r",
    refresh_view = "R",
    open_actions = "A",
    open_in_browser = "gx",
    copy_url = "Y",
    show_details = "K",
    search = "?",
  },
  issues = {
    copy_key = "y",
    transition_issue = "gs",
    change_assignee = "ga",
    change_reporter = "gr",
    edit_issue = "ge",
    create_issue = "c",
  },
  pulls = {
    copy_id = "y",
    open_diff = "gd",
    checkout = "gc",
    review = {
      toggle_layout = "t",
      toggle_compact = "f",
      next_hunk = "]h",
      previous_hunk = "[h",
      next_file = { "]f", "<Tab>" },
      previous_file = { "[f", "<S-Tab>" },
      toggle_file_reviewed = "-",
      toggle_commits = "gC",
      next_comment = "]c",
      previous_comment = "[c",
      next_note = "]n",
      previous_note = "[n",
      view_thread = "K",
      add_pending_comment = "c",
      add_comment = "C",
      add_note = "n",
      toggle_resolved = "x",
    },
    filter_status_open = "gpo",
    filter_status_merged = "gpm",
    filter_status_declined = "gpd",
  },
},
```

## Contributors ✨

Thanks go to these wonderful people ([emoji key](https://allcontributors.org/emoji-key)):

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="14.28%"><a href="http://khanriza.com"><img src="https://avatars.githubusercontent.com/u/51720003?v=4?s=100" width="100px;" alt="Riza Khan"/><br /><sub><b>Riza Khan</b></sub></a><br /><a href="#code-RizaHKhan" title="Code">💻</a></td>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/cryptus9"><img src="https://avatars.githubusercontent.com/u/35228091?v=4?s=100" width="100px;" alt="Cydralic"/><br /><sub><b>Cydralic</b></sub></a><br /><a href="#code-cryptus9" title="Code">💻</a></td>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/franroa"><img src="https://avatars.githubusercontent.com/u/2432583?v=4?s=100" width="100px;" alt="franroa"/><br /><sub><b>franroa</b></sub></a><br /><a href="#code-franroa" title="Code">💻</a> <a href="#bug-franroa" title="Bug reports">🐛</a></td>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/eertmanhidde"><img src="https://avatars.githubusercontent.com/u/45388384?v=4?s=100" width="100px;" alt="hiddederidder"/><br /><sub><b>hiddederidder</b></sub></a><br /><a href="#code-eertmanhidde" title="Code">💻</a></td>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/xamcost"><img src="https://avatars.githubusercontent.com/u/24434420?v=4?s=100" width="100px;" alt="Xamcost"/><br /><sub><b>Xamcost</b></sub></a><br /><a href="#code-xamcost" title="Code">💻</a></td>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/niklastreml"><img src="https://avatars.githubusercontent.com/u/27763017?v=4?s=100" width="100px;" alt="Niklas Treml"/><br /><sub><b>Niklas Treml</b></sub></a><br /><a href="#code-niklastreml" title="Code">💻</a> <a href="#bug-niklastreml" title="Bug reports">🐛</a></td>
    </tr>
  </tbody>
</table>

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->

## License

MIT License - see [LICENSE](LICENSE) for details.
