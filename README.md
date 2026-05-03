[![Neovim](https://img.shields.io/badge/Neovim-0.10+-blue.svg)](https://neovim.io/)
[![Version](https://img.shields.io/github/v/tag/emrearmagan/atlas.nvim.svg)](https://github.com/emrearmagan/atlas.nvim/tags)
[![Tests](https://github.com/emrearmagan/atlas.nvim/actions/workflows/main.yml/badge.svg)](https://github.com/emrearmagan/atlas.nvim/actions/workflows/main.yml)
[![License](https://img.shields.io/github/license/emrearmagan/atlas.nvim?style=flat-square&color=blue)](LICENSE)

# Atlas.nvim

A Neovim plugin for managing GitHub/Bitbucket PRs and Jira issues without leaving your editor.

> [!CAUTION]
> **Still in early development, will have breaking changes!**

<img width="4566" height="2488" alt="Jira" src="https://github.com/user-attachments/assets/23a15b90-283c-45e2-8964-02970ec3b21a" />
<img width="4566" height="2488" alt="Bitbucket" src="https://github.com/user-attachments/assets/06299ffc-b15b-4e2c-8f11-95a8ddde3b04" />

## Table of Contents

- [Installation](#installation)
- [Issues](#issues)
  - [Jira](#jira)
- [Pulls](#pulls)
  - [GitHub](#github)
  - [Bitbucket](#bitbucket)

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "emrearmagan/atlas.nvim",
  dependencies = {
    "MeanderingProgrammer/render-markdown.nvim", -- optional but recommended (Jira)
    "sindrets/diffview.nvim", -- optional (PullRequest diff)
    "esmuellert/codediff.nvim", -- optional (PullRequest diff alternative)
  },
  config = function()
    require("atlas").setup({
      pulls = {
        providers = {
          bitbucket = { }, -- See configuration below
          github = { },    -- See configuration below
        },
      },
      issues = {
        providers = {
          jira = { }, -- See configuration below
        },
      },
    })
  end,
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
          bitbucket = { }, -- See configuration below
          github = { },    -- See configuration below
        },
      },
      issues = {
        providers = {
          jira = { }, -- See configuration below
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

> [!NOTE]
> I have only tested this with my personal and work accounts. If you encounter any issues, please feel free to open an issue.
> See: https://support.atlassian.com/atlassian-account/docs/manage-api-tokens-for-your-atlassian-account/

## Commands

- `:AtlasIssues [provider]` - Open Atlas issues domain
- `:AtlasPulls [provider]` - Open Atlas pulls domain
- `:AtlasCreatePR` - Create a pull request from the current branch (auto-detects repo + provider)
- `:AtlasJqlSearch {query}` - Search Jira issues with JQL
- `:AtlasClearCache` - Clear Atlas disk and memory cache
- `:AtlasLogs` - Toggle Atlas logs

## Issues

> [!TIP]
> Not ready to connect to Jira yet? Run `:AtlasIssues mock` to explore the UI with local mock data.

### Jira

- [x] Create and Edit issues
- [x] View and edit issues as markdown -> ADF conversion for issue descriptions (experimental)
- [x] Issue panel tabs: overview, comments, history
- [x] Jira actions: transition, change assignee, change reporter, edit title
- [x] Comment workflows (create, reply, edit, delete)
- [x] Search issues
- [x] JQL support and completion
- [x] Support for custom fields
- [x] Add custom actions to issues
- [x] Create and edit issue templates
- [ ] Save JQL queries as custom views
- [ ] Save and filter issues

> [!IMPORTANT]
> The markdown editor for issue descriptions and comments is still experimental and may not work perfectly in all cases. You can toggle between markdown and ADF view in the overview tab to see the raw ADF content and how it translates to markdown. If you encounter any issues with the markdown editor, please open an issue with details.

<div>
    <img width = "49%" alt="Edit/Create Issue" src="https://github.com/user-attachments/assets/76913fbf-1667-4f35-9962-d3c1b4619c7f" />
    <img width = "49%"alt="Jira Panel" src="https://github.com/user-attachments/assets/e188582e-f784-46a8-aacd-ac989054c378" />
</div>

<details>
<summary><strong>Configuration</strong></summary>

```lua
return {
  "emrearmagan/atlas.nvim",
  config = function()
    require("atlas").setup({
      issues = {
        max_results = 100,
        fetch_parent_issues = true,
        custom_actions = {}, -- See Custom Actions below.

        providers = {
          jira = {
            base_url = "https://your-site.atlassian.net",
            email = "you@example.com",
            --- See: https://support.atlassian.com/atlassian-account/docs/manage-api-tokens-for-your-atlassian-account/
            token = "your_jira_api_token",
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
                jql = "project = KAN AND assignee = currentUser() ORDER BY updated DESC",
              },
              {
                name = "Team Board",
                key = "T",
                jql = "project = KAN ORDER BY updated DESC",
              },
            },
          },
        },
      },
    })
  end,
}
```

</details>

<details>
<summary><strong>Custom Actions</strong></summary>

You can add custom issue actions under `issues.custom_actions`.

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
  providers = {
    jira = { },
  },
}
```

</details>

#### JQL Search Command

Use `:AtlasJqlSearch` to run JQL directly from command mode. It also supports command-line completion while typing the query.

Examples:

```vim
:AtlasJqlSearch project = KAN AND assignee = currentUser() ORDER BY updated DESC
:AtlasJqlSearch summary ~ "login bug"
```

## Pulls

> [!TIP]
> Not ready to connect? Run `:AtlasPulls mock` to explore the UI with local mock data.

- [x] Multiple views
- [x] PR tabs: overview, activity, comments, commits, files
- [x] PR actions: merge, approve, request changes
- [x] Comment workflows (create, reply, edit, delete)
- [x] Build/CI status with clickable links
- [x] Diffstat summary in Changes tab
- [x] Add custom actions to PRs
- [x] Open PR diff in given command
- [x] Switch between open, merged and closed PRs
- [x] Show Github Issues
- [x] Show Notifications
- [x] Create pull requests (`:AtlasCreatePR`)
- [ ] Pagination for API results

### GitHub

<details>
<summary><strong>Configuration</strong></summary>

```lua
return {
  "emrearmagan/atlas.nvim",
  config = function()
    require("atlas").setup({
      pulls = {
        diff = {
          -- Command must support range input: origin/<destination>...origin/<source>
          open_cmd = "DiffviewOpen", -- e.g. "DiffviewOpen" or "CodeDiff", defaults to nil.
        },
        providers = {
          github = {
            cache_ttl = 300,

            ---@type AtlasGitHubViewConfig[]
            views = {
              {
                name = "My PRs",
                key = "1",
                search = "author:@me sort:updated-desc",
              },
              {
                name = "Team",
                key = "2",
                search = "org:your-org sort:updated-desc",
              },
              {
                name = "Repo",
                key = "3",
                search = "repo:your-org/your-repo",
              },
            },
          },
        },
      },
    })
  end,
}
```

</details>

### Bitbucket

<details>
<summary><strong>Configuration</strong></summary>

```lua
return {
  "emrearmagan/atlas.nvim",
  config = function()
    require("atlas").setup({
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
            },
          },
        },
        custom_actions = {}, -- See Custom Actions below.
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
                layout = "compact", -- "compact" or "plain"
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
    })
  end,
}
```

</details>

<details>
<summary><strong>Custom Actions</strong></summary>

You can add custom PR actions under `pulls.custom_actions`.

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
    bitbucket = { },
  },
}
```

![CleanShot2026-03-31at20 08 06-ezgif com-video-to-gif-converter](https://github.com/user-attachments/assets/a8ca355b-09e2-428c-b3fb-3280fd161110)

</details>

#### Keymaps

Set an action to `false` to disable it, or set it to a list to add aliases.

```lua
require("atlas").setup({
  keymaps = {
    ui = {
      toggle_panel = false,
      next_panel_tab = { "]", "<Tab>", "gn" },
      previous_panel_tab = { "[", "<S-Tab>", "gp" },
    },
    issues = {
      transition_issue = "gs",
      change_assignee = "ga",
      edit_issue = "ge",
      search = "?",
    },
    pulls = {
      open_diff = { "go", "gd" },
    },
  },
})
```

##### General

| Context | Key                     | Action                              |
| ------- | ----------------------- | ----------------------------------- |
| Atlas   | `q`                     | Close Atlas                         |
| Atlas   | `g?`                    | Toggle help popup                   |
| Atlas   | `p`                     | Toggle detail pane                  |
| Atlas   | `<S-Tab>`               | Previous panel tab                  |
| Atlas   | `<Tab>`                 | Next panel tab                      |
| Atlas   | `R`                     | Refresh current view                |
| Atlas   | `r`                     | Refresh selected issue/pr           |
| Atlas   | `a/i` / `c` / `e` / `d` | Add / reply / edit / delete comment |

##### Issues

| Context | Key         | Action                                    |
| ------- | ----------- | ----------------------------------------- |
| Issues  | `A`         | Open Jira actions                         |
| Issues  | `K`         | Show issue details                        |
| Issues  | `c`         | Create issue                              |
| Issues  | `?`         | Search issues                             |
| Issues  | `gs`        | Transition issue                          |
| Issues  | `ga`        | Change assignee                           |
| Issues  | `gr`        | Change reporter                           |
| Issues  | `ge`        | Edit issue                                |
| Issues  | `gx`        | Open issue/comment in browser             |
| Issues  | `y` / `Y`   | Copy issue key / URL                      |
| Issues  | `za` / `zA` | Toggle fold / all folds                   |
| Issues  | `m`         | Toggle markdown / raw view (overview tab) |

##### Pulls

| Context              | Key         | Action                           |
| -------------------- | ----------- | -------------------------------- |
| Pulls                | `A`         | Open PR actions                  |
| Pulls                | `o`         | Toggle repository panel          |
| Pulls                | `T`         | Create new tasks on PR           |
| Pulls                | `?`         | Search repositories              |
| Pulls                | `gc`        | Checkout selected PR             |
| Pulls                | `gd`        | Open selected PR diff            |
| Pulls                | `gx`        | Open pr/build/comment in browser |
| Pulls                | `y` / `Y`   | Copy PR id / URL                 |
| Pulls (File changes) | `za` / `zA` | Toggle fold / all folds          |
| Pulls (File changes) | `]h` / `[h` | Next / previous hunk             |

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
    </tr>
  </tbody>
</table>

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->

## License

MIT License - see [LICENSE](LICENSE) for details.
