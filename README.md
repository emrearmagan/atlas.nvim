[![Neovim](https://img.shields.io/badge/Neovim-0.10+-blue.svg)](https://neovim.io/)
[![Version](https://img.shields.io/github/v/tag/emrearmagan/atlas.nvim.svg)](https://github.com/emrearmagan/atlas.nvim/tags)
[![Tests](https://github.com/emrearmagan/atlas.nvim/actions/workflows/main.yml/badge.svg)](https://github.com/emrearmagan/atlas.nvim/actions/workflows/main.yml)
[![License](https://img.shields.io/github/license/emrearmagan/atlas.nvim?style=flat-square&color=blue)](LICENSE)

# Atlas.nvim

A Neovim plugin for managing GitHub/Bitbucket PRs and Jira issues without leaving your editor.

> [!CAUTION]
> **Still in early development, will have breaking changes!**

<table>
	<tr>
     <td width="50%">
      <img src="https://github.com/user-attachments/assets/caa30d3c-6883-4f2e-bc12-81bb2127f798"><br/>
      Github
    </td>
     <td width="50%">
      <img src="https://github.com/user-attachments/assets/06299ffc-b15b-4e2c-8f11-95a8ddde3b04"><br/>
      Bitbucket
    </td>
  </tr>
  <tr>
	<td width="50%">
	    <img src="https://github.com/user-attachments/assets/23a15b90-283c-45e2-8964-02970ec3b21a"><br/>
	</td>
    <td width="50%">
		<img alt="Edit/Create Issue" src="https://github.com/user-attachments/assets/76913fbf-1667-4f35-9962-d3c1b4619c7f" />
    </td>
  </tr>
</table>

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
> Not ready to connect yet? Run `:AtlasIssues mock` or `:AtlasPulls mock` to explore the UI with some mock data.

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
- `:AtlasCreatePR` - Create a pull request from the current branch
- `:AtlasJqlSearch {query}` - Search Jira issues with JQL
- `:AtlasClearCache` - Clear Atlas disk and memory cache
- `:AtlasLogs` - Toggle Atlas logs

## Issues

### Jira

> [!NOTE]
> If you're only looking for Jira support, check out https://github.com/letieu/jira.nvim. This plugin was the main inspiration for this project.  
> Jira support is included here mainly because I wanted a single tool that works with both Atlassian products.

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

### Configuration

```lua
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
          pr_template = ".github/pull_request_template.md", -- optional, defaults to .github/pull_request_template.md
        },
      },
    },
    custom_actions = {}, -- See Custom Actions below.
  },
})
```

### GitHub

<details>
<summary><strong>Configuration</strong></summary>

```lua
return {
  "emrearmagan/atlas.nvim",
  config = function()
    require("atlas").setup({
      pulls = {
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

#### Keymaps

Set an action to `false` to disable it, or set it to a list to add aliases.

```lua
require("atlas").setup({
  keymaps = {
    ui = {
      help = "g?",
      close = "q", -- false would disable it
      toggle_panel = "p", -- { "p", "k" } would add aliases
      toggle_fold = "za",
      toggle_all_folds = "zA",
      previous_panel_tab = "<S-Tab>",
      next_panel_tab = "<Tab>",
    },
    issues = {
      open_actions = "A",
      open_in_browser = "gx",
      copy_url = "Y",
      copy_key = "y",
      show_details = "K",
      search = "?",
      refresh = "r",
      refresh_view = "R",
      transition_issue = "gs",
      change_assignee = "ga",
      change_reporter = "gr",
      edit_issue = "ge",
      create_issue = "c",
    },
    pulls = {
      refresh = "r",
      refresh_view = "R",
      open_actions = "A",
      open_in_browser = "gx",
      copy_url = "Y",
      copy_id = "y",
      open_diff = "gd",
      checkout = "gc",
      show_details = "K",
      search = "?",
      open_notifications = "N",
      notifications_mark_read = "r",
      notifications_mark_done = "d",
      notifications_refresh = "R",
      pr_files_next_hunk = "]h",
      pr_files_previous_hunk = "[h",
      filter_status_open = "gpo",
      filter_status_merged = "gpm",
      filter_status_declined = "gpd",
    },
  },
})
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
    </tr>
  </tbody>
</table>

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->

## License

MIT License - see [LICENSE](LICENSE) for details.
