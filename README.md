[![Neovim](https://img.shields.io/badge/Neovim-0.10+-blue.svg)](https://neovim.io/)
[![Version](https://img.shields.io/github/v/tag/emrearmagan/atlas.nvim.svg)](https://github.com/emrearmagan/atlas.nvim/tags)
[![CI](https://github.com/emrearmagan/atlas.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/emrearmagan/atlas.nvim/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/emrearmagan/atlas.nvim?style=flat-square&color=blue)](LICENSE)

# Atlas.nvim

A Neovim plugin for managing GitHub/Bitbucket/GitLab PRs and Jira/GitHub/GitLab issues without leaving your editor.

<p>
  <img alt="GitHub" src="https://img.shields.io/badge/GitHub-181717?style=flat-square&logo=github&logoColor=white">
  <img alt="Bitbucket" src="https://img.shields.io/badge/Bitbucket-0052CC?style=flat-square&logo=bitbucket&logoColor=white">
  <img alt="GitLab" src="https://img.shields.io/badge/GitLab-FC6D26?style=flat-square&logo=gitlab&logoColor=white">
  <img alt="Jira" src="https://img.shields.io/badge/Jira-0052CC?style=flat-square&logo=jira&logoColor=white">
</p>

<img alt="Atlas UI" src="https://github.com/user-attachments/assets/de6459f9-f123-40a6-acbd-097a17e7ae86" />

> [!CAUTION]
> **Still in early development, will have breaking changes!**

## Table of Contents

- [Installation](#installation)
- [Requirements](#requirements)
- [Configuration](#configuration)
- [Commands](#commands)
- [Pulls](#pulls)
  - [Configuration](#pulls-configuration)
    - [GitHub](#github)
    - [Bitbucket](#bitbucket)
    - [GitLab](#gitlab)
- [Issues](#issues)
  - [Configuration](#issue-configuration)
    - [Jira](#jira)
    - [GitHub](#github-issues)
    - [GitLab](#gitlab-issues)
- [Features](#features)
- [Events](#events)
- [Keymaps](#keymaps)
- [Contributing](#contributing)

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "emrearmagan/atlas.nvim",
  dependencies = {
    "nvim-tree/nvim-web-devicons", -- optional but recommended
    "MeanderingProgrammer/render-markdown.nvim", -- optional but recommended
    "esmuellert/codediff.nvim", -- optional (PullRequest diff)
    "sindrets/diffview.nvim", -- optional; or "dlyongemallo/diffview-plus.nvim"
  },
  -- See Configuration below
  opts = {},
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "emrearmagan/atlas.nvim",
  config = function()
    -- See Configuration below
    require("atlas").setup({})
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

## Configuration

```lua
{
  -- Too lazy to manage a statusline per split? Same. Make it global.
  global_statusline = true,

  pulls = {
    -- See Pulls Configuration below.
    providers = {
      ---@type AtlasBitbucketConfig
      bitbucket = {},
      ---@type AtlasGitHubConfig
      github = {},
      ---@type AtlasGitLabPullsConfig
      gitlab = {},
    },
  },
  issues = {
    -- See Issue Configuration below.
    providers = {
      ---@type AtlasJiraIssuesConfig
      jira = {},
      ---@type AtlasGitHubIssuesConfig
      github = {},
      ---@type AtlasGitLabIssuesConfig
      gitlab = {},
    },
  },
}
```

Set `global_statusline = false` to leave Neovim's `laststatus` option unchanged.

## Commands

- `:Atlas` - Pick a command
- `:Atlas pulls [provider]` / `:Atlas issues [provider]` - Open a provider dashboard
- `:Atlas review [pull-request-url]` - Review a pull request with the configured diff viewer
- `:Atlas diff <base>...<head>` or `:Atlas diff <pull-request-url>` - Open native AtlasDiff
- `:Atlas notes [target]` / `:Atlas clear-notes` - Inspect or delete local review notes
- `:Atlas create-pr` / `:Atlas create-issue` - Create a pull request or issue
- `:Atlas search [provider]` - Search configured pull-request and issue providers
- `:Atlas open <target>` - Open a provider URL, Jira key, repository reference, or PR/issue number
- `:Atlas clear-cache` / `:Atlas logs` - Clear caches or toggle Atlas logs
- `:AtlasDiff <base>...<head>` or `:AtlasDiff <pull-request-url>` - Retained as the native diff-viewer command

## Pulls

Use `:Atlas pulls [provider]` to browse and manage pull requests from GitHub, Bitbucket, and GitLab.

### Pulls Configuration

```lua
pulls = {
  delete_notes = false, -- Delete local PR notes after approval or merge.
  default_merge_method = "merge", -- "merge" or "squash".
  default_delete_branch = false,

  diff = {
    -- Any command that accepts explicit <base>...<head> Git revisions.
    open_cmd = "AtlasDiff", -- default; for example "DiffviewOpen" or "CodeDiff".
    show_review_panel = false, -- Set true to show the review panel when a diff opens.
    show_comments = true, -- Show full comment and note cards; false uses compact inline hints.

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

<a id="github"></a>

<details>
<summary><strong>GitHub</strong></summary>

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

<img alt="GitHub pull requests" src="https://github.com/user-attachments/assets/8b570bb3-d073-4ab0-99fc-2d9179e173cd">

</details>

<a id="bitbucket"></a>

<details>
<summary><strong>Bitbucket</strong></summary>

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

<img alt="Bitbucket pull requests" src="https://github.com/user-attachments/assets/bcdd0c9c-e15f-4e82-81fd-cde38aa68a2d">

</details>

<a id="gitlab"></a>

<details>
<summary><strong>GitLab</strong></summary>

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

<img alt="GitLab pull requests" src="https://github.com/user-attachments/assets/128fe916-e733-4abb-9c5c-5244684f3c41">

</details>

## Issues

Use `:Atlas issues [provider]` to browse and manage Jira, GitHub, and GitLab issues.

### Issue Configuration

```lua
issues = {
  max_results = 100,
  with_relationships = true, -- Fetch parent/subissue relationships for plain issue tree views.
  custom_actions = {}, -- See Custom Actions below.
}
```

<a id="jira"></a>

<details>
<summary><strong>Jira</strong></summary>

> [!NOTE]
> If you're only looking for Jira support, check out https://github.com/letieu/jira.nvim. This plugin was the main inspiration for this project.
> Jira support is included here mainly because I wanted a single tool that works with both Atlassian products.

> [!IMPORTANT]
> The markdown editor for issue descriptions and comments is still experimental and may not work perfectly in all cases. You can toggle between markdown and ADF view in the overview tab to see the raw ADF content and how it translates to markdown. If you encounter any issues with the markdown editor, please open an issue with details.

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

<img alt="Jira issues" src="https://github.com/user-attachments/assets/4cb40f1f-0b18-4fb1-82ae-6bc57fc8a7c5">

</details>

<a id="github-issues"></a>

<details>
<summary><strong>GitHub Issues</strong></summary>

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

<a id="gitlab-issues"></a>

<details>
<summary><strong>GitLab Issues</strong></summary>

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

## Features

Keep the pull request and issue workflows you use throughout the day inside Neovim.

### Review Pull Requests

<img alt="AtlasDiff" src="https://github.com/user-attachments/assets/7280373a-f6e9-4847-be64-89e245d461cd" />

Run `:Atlas review` inside a Git repository to pick one of its open or draft pull requests, or pass a pull-request URL directly. Atlas opens the configured diff viewer.

Press the configured `pulls.open_diff` key (`gd` by default) on a pull request to start a review.

- See pending, resolved, and outdated provider threads at their diff locations.
- Review provider tasks and GitHub checklists alongside the comments they belong to.
- Add, reply to, edit, delete, resolve, or reopen comments when supported.
- Browse comments, tasks, and local notes
- Mark files reviewed in AtlasDiff; GitHub syncs the state with the pull request.
- Submit pending comments with an optional review summary when supported.

> [!NOTE]
> **Alternative viewers:** CodeDiff, [Diffview](https://github.com/sindrets/diffview.nvim), and [Diffview-plus](https://github.com/dlyongemallo/diffview-plus.nvim) can display Atlas comment, task, and local-note overlays, but their integrations rely on plugin internals and may break after upstream changes.

#### Local notes

<img align="left" width="54%" hspace="16" vspace="8" alt="Local review notes" src="https://github.com/user-attachments/assets/8652d731-b57f-45f8-896e-d62d0ec8d7f4">

Local notes let you leave something on a diff without posting it to the pull request. Each note is attached to a file and line and can be an `ISSUE`, `SUGGESTION`, `NOTE`, or `PRAISE`. Diff views mark notes as outdated when their saved line changes.

<br clear="both">

For scripts, use `bin/atlas-notes`. Notes added there appear in AtlasDiff, CodeDiff, Diffview, Diffview-plus, and `:Atlas notes`:

```sh
./bin/atlas-notes add \
  --target https://github.com/owner/repository/pull/123 \
  --file lua/review_queue.lua --line 19 \
  --context "local item = queue[index]" \
  --type suggestion --body "Should this be a bool?"
```

My dotfiles include a [Pi extension that wraps this script](https://github.com/emrearmagan/dotfiles/blob/main/config/pi/extensions/atlas-notes.ts) so review agents can list and add notes.

### View Pipelines

<img align="left" width="54%" hspace="16" vspace="8" alt="View pipelines" src="https://github.com/user-attachments/assets/c625c4e8-b1ad-4772-b46b-24718ba6fbb7">

View pipelines and their jobs, inspect their status, and read job logs directly in Atlas. Retry failed pipelines or jobs and cancel work that is still running.

<br clear="both">

### Create Pull Requests

<img align="right" width="54%" hspace="16" vspace="8" alt="Create pull request" src="https://github.com/user-attachments/assets/d6335c66-35f7-4495-b83a-53819d7ec7d5">

`:Atlas create-pr` opens the pull request form for the current branch. The newest commit supplies the title. Atlas first reads the configured `pr_template`, or `.github/pull_request_template.md` by default.

Without a template, Atlas groups conventional commits into sections, recognizes leading Jira keys such as `[JIRA-123]`, links commit hashes and issue references, collects references under **Related**, and appends the diffstat. If no commits use a conventional prefix, it uses a linked plain commit list instead.

Edit the title and description, choose the target branch and reviewers, set the draft state, or preview commits and diffstat before submitting.

<br clear="both">

### Create Issues

<img align="left" width="54%" hspace="16" vspace="8" alt="Create issue" src="https://github.com/user-attachments/assets/8f3b06d8-763d-4e0f-ab93-9c3754065ca3">

`:Atlas create-issue` opens the creation flow for the configured issue providers. GitHub and GitLab use the current repository, while Jira uses the configured instance. The forms support Markdown descriptions and provider-specific fields such as labels, assignees, milestones, and Jira issue types.

GitHub, GitLab, and Jira can apply a saved Markdown template or save the current description as a new one. Templates are shared between providers and stored under Neovim's data directory.

<br clear="both">

### Notifications

<img align="right" width="54%" hspace="16" vspace="8" alt="Notifications" src="https://github.com/user-attachments/assets/117b5ad7-3840-4487-bd91-f2f9bf213428">

Open GitHub and GitLab notifications inside Atlas, refresh them, open the related item, and mark notifications as read or done without leaving Neovim.

Keep the work that needs your attention visible.

<br clear="both">

### Bookmarks

<img align="left" width="54%" hspace="16" vspace="8" alt="Bookmarks" src="https://github.com/user-attachments/assets/f008d6af-dfc6-4b65-8af1-94cd6ce9fc99">

Turn frequently used GitHub and GitLab searches or Jira JQL into named shortcuts. Use bookmarks for review queues, recurring project views, and the searches you return to throughout the day.

Bookmarks appear alongside your configured views, keeping important queries one action away.

<br clear="both">

### Custom Actions

<img align="right" width="54%" hspace="16" vspace="8" alt="Atlas custom action" src="https://github.com/user-attachments/assets/a8ca355b-09e2-428c-b3fb-3280fd161110">

Add project-specific actions to pull requests and issues. Custom actions receive the current item and provider context, making it possible to call local scripts, open repositories in tmux, copy branch names, or connect Atlas to your own tooling.

<br clear="both">

<details>
<summary><strong>Configuration</strong></summary>

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
},
```

Use `ctx.output(title)` to show output from a custom action:

```lua
output:write("Loading...")
output:run(cmd, on_exit, { cwd = "/repo" })
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
    next_item = "j",
    previous_item = "k",
    first_item = "gg",
    last_item = "G",
    submit = "<C-s>",
    help = "g?", -- { "g?", "<leader>?" } would add aliases
    close = "q", -- false would disable it
    toggle_panel = "p",
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
    copy_id = "y",
    copy_url = "Y",
    show_details = "K",
    search = "?",
  },
  issues = {
    transition_issue = "gs",
    change_assignee = "ga",
    change_reporter = "gr",
    edit_issue = "ge",
    create_issue = "c",
  },
  pulls = {
    open_diff = "gd",
    checkout = "gc",
    edit_title = "T",
    edit_description = "D",
    review = {
      show_item = "<CR>",
      focus_item = "gd",
      toggle_approval = "ga",
      request_changes = "gr",
      submit_review = "gs",
      explorer = {
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
        toggle_compact = "u",
        next_hunk = "]h",
        previous_hunk = "[h",
        toggle_review_panel = "gR",
        toggle_comments = "gH",
        next_comment = "]c",
        previous_comment = "[c",
        next_note = "]n",
        previous_note = "[n",
        add_comment = "c",
        submit_comment = "C",
        edit_comment = "e",
        delete = "dd",
        add_note = "<leader>n",
        add_task = "T",
        toggle_resolved = "x",
      },
    },
    pipelines = {
      open = "gd",
    },
    filters = {
      open = "gpo",
      merged = "gpm",
      declined = "gpd",
    },
  },
},
```

## Contributing

Contributions are welcome! If you'd like to contribute, please open an [issue](https://github.com/emrearmagan/atlas.nvim/issues) or [pull request](https://github.com/emrearmagan/atlas.nvim/pulls) on GitHub. See [CONTRIBUTING.md](CONTRIBUTING.md).

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
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/TheNoeTrevino"><img src="https://avatars.githubusercontent.com/u/144077737?v=4?s=100" width="100px;" alt="Noe Trevino"/><br /><sub><b>Noe Trevino</b></sub></a><br /><a href="#code-TheNoeTrevino" title="Code">💻</a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="14.28%"><a href="https://nuagir.com"><img src="https://avatars.githubusercontent.com/u/35815402?v=4?s=100" width="100px;" alt="Jean-Frederic Mainville"/><br /><sub><b>Jean-Frederic Mainville</b></sub></a><br /><a href="#code-jfmainville" title="Code">💻</a></td>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/23andreas"><img src="https://avatars.githubusercontent.com/u/12485755?v=4?s=100" width="100px;" alt="23andreas"/><br /><sub><b>23andreas</b></sub></a><br /><a href="#code-23andreas" title="Code">💻</a></td>
    </tr>
  </tbody>
</table>

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->

## License

MIT License - see [LICENSE](LICENSE) for details.
