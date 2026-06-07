[![Neovim](https://img.shields.io/badge/Neovim-0.10+-blue.svg)](https://neovim.io/)
[![Version](https://img.shields.io/github/v/tag/emrearmagan/atlas.nvim.svg)](https://github.com/emrearmagan/atlas.nvim/tags)
[![Tests](https://github.com/emrearmagan/atlas.nvim/actions/workflows/main.yml/badge.svg)](https://github.com/emrearmagan/atlas.nvim/actions/workflows/main.yml)
[![License](https://img.shields.io/github/license/emrearmagan/atlas.nvim?style=flat-square&color=blue)](LICENSE)

# Atlas.nvim

A Neovim plugin for managing GitHub/Bitbucket/GitLab PRs and Jira/GitHub/GitLab issues without leaving your editor.

> [!CAUTION]
> **Still in early development, will have breaking changes!**

<table>
  <thead>
    <tr>
      <th width="50%" align="center">GitHub</th>
      <th width="50%" align="center">Bitbucket</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td width="50%"><img alt="GitHub PRs" src="https://github.com/user-attachments/assets/caa30d3c-6883-4f2e-bc12-81bb2127f798"></td>
      <td width="50%"><img alt="Bitbucket PRs" src="https://github.com/user-attachments/assets/06299ffc-b15b-4e2c-8f11-95a8ddde3b04"></td>
    </tr>
    <tr>
      <th width="50%" align="center">GitLab</th>
      <th width="50%" align="center">Jira</th>
    </tr>
    <tr>
	  <td width="50%"><img alt="Jira" src="https://github.com/user-attachments/assets/81b4023b-7f36-47cf-aeaf-28f9c1ebeb76"></td>
      <td width="50%"><img alt="Jira" src="https://github.com/user-attachments/assets/23a15b90-283c-45e2-8964-02970ec3b21a"></td>
    </tr>
  </tbody>
</table>

## Table of Contents

- [Installation](#installation)
- [Issues](#issues)
  - [Jira](#jira)
  - [GitHub](#github-issues)
  - [GitLab](#gitlab-issues)
- [Pulls](#pulls)
  - [GitHub](#github)
  - [Bitbucket](#bitbucket)
  - [GitLab](#gitlab)

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "emrearmagan/atlas.nvim",
  dependencies = {
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
- Jira: Jira Cloud REST API v3 (`*.atlassian.net`)
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
- `:AtlasCreatePR` - Create a pull request from the current branch
- `:AtlasCreateIssue` - Create an issue (GitHub / Jira)
- `:AtlasSearch [provider]` - Pick a configured provider and prompt its search
- `:AtlasClearCache` - Clear Atlas disk and memory cache
- `:AtlasLogs` - Toggle Atlas logs

## Issues

- [x] Create and edit issues
- [x] View and edit issues as markdown -> ADF conversion for descriptions (experimental)
- [x] Issue tabs: overview, comments, activity
- [x] Manage and edit issues (e.g. transition, assign, edit reporter, edit title, delete)
- [x] Comment workflows (create, reply, edit, delete)
- [x] Search issues
- [x] JQL support and completion
- [x] Support for custom fields
- [x] Subscribe / unsubscribe to issues
- [x] Add custom actions to issues
- [x] Create and edit issue templates
- [ ] Save JQL queries as custom views
- [ ] Save and filter issues

### Jira

> [!NOTE]
> If you're only looking for Jira support, check out https://github.com/letieu/jira.nvim. This plugin was the main inspiration for this project.  
> Jira support is included here mainly because I wanted a single tool that works with both Atlassian products.

> [!IMPORTANT]
> The markdown editor for issue descriptions and comments is still experimental and may not work perfectly in all cases. You can toggle between markdown and ADF view in the overview tab to see the raw ADF content and how it translates to markdown. If you encounter any issues with the markdown editor, please open an issue with details.

<details>
<summary><strong>Configuration</strong></summary>

```lua
issues = {
  max_results = 100,
  with_relationships = true, -- Fetch parent/subissue relationships for plain issue tree views.
  custom_actions = {}, -- See Custom Actions below.

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
    },
  },
},
```

<img alt="Edit/Create Issue" src="https://github.com/user-attachments/assets/76913fbf-1667-4f35-9962-d3c1b4619c7f">

</details>

### GitHub Issues

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
    },
  },
},
```

</details>

### GitLab Issues

<details>
<summary><strong>Configuration</strong></summary>

Auth uses a [Personal Access Token](https://docs.gitlab.com/ee/user/profile/personal_access_tokens.html) with the `api` scope. Set `base_url` to `https://gitlab.com` or your self-hosted instance.

```lua
issues = {
  providers = {
    gitlab = {
      base_url = "https://gitlab.com",
      token = os.getenv("GITLAB_TOKEN") or "",
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
    },
  },
},
```

</details>

### Custom Actions

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

## Pulls

- [x] Multiple views
- [x] PR tabs: overview, activity, comments, commits, files
- [x] PR actions: merge, approve, request changes, convert to draft, edit reviewers etc.
- [x] Comment workflows (create, reply, edit, delete)
- [x] Build/CI status
- [x] Diffstat summary
- [x] Checkout PR branch
- [x] Add custom actions to PRs
- [x] Open PR diff in given command
- [x] Switch between open, merged and closed PRs
- [x] Subscribe / unsubscribe to PRs
- [x] Show notifications
- [x] Create pull requests (`:AtlasCreatePR`)
- [ ] Pagination for API results

### Configuration

```lua
pulls = {
  diff = {
    -- Command must support range input: origin/<destination>...origin/<source>
    open_cmd = "DiffviewOpen", -- e.g. "DiffviewOpen" or "CodeDiff", defaults to nil.
  },
  repo_config = {
    -- Maps `workspace/repo` to local paths. Used for checkout and custom actions.
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

### GitHub

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
    },
  },
},
```

</details>

### Bitbucket

<details>
<summary><strong>Configuration</strong></summary>

```lua
pulls = {
  providers = {
    bitbucket = {
      user = os.getenv("BITBUCKET_USER") or "",
      token = os.getenv("BITBUCKET_TOKEN") or "",
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

</details>

### GitLab

<details>
<summary><strong>Configuration</strong></summary>

Auth uses a [Personal Access Token](https://docs.gitlab.com/ee/user/profile/personal_access_tokens.html) with the `api` scope. Set `base_url` to `https://gitlab.com` or your self-hosted instance.

```lua
pulls = {
  providers = {
    gitlab = {
      base_url = "https://gitlab.com",
      token = os.getenv("GITLAB_TOKEN") or "",
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
    },
  },
},
```

</details>

### Custom Actions

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

## Search

Use `:AtlasSearch [provider]` to search configured providers.

### Jira

`:AtlasSearch jira` opens a JQL prompt with full completion (fields, operators, values).

```
project = KAN AND assignee = currentUser() ORDER BY updated DESC
summary ~ "login bug"
```

### GitHub

`:AtlasSearch github` opens a GitHub search prompt with completion (`is:`, `repo:`, `author:`, `label:` etc.).

```
is:pr is:open author:@me
is:issue label:bug
```

### Bitbucket

`:AtlasSearch bitbucket` asks for a workspace and a repository and opens the UI scoped to that repo.

#### Keymaps

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
    next_hunk = "]h",
    previous_hunk = "[h",
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
    </tr>
  </tbody>
</table>

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->

## License

MIT License - see [LICENSE](LICENSE) for details.
