local M = {}

local cli = require("atlas.pulls.providers.gitea.api.cli")
local footer = require("atlas.ui.components.footer")
local checkout = require("atlas.core.git.checkout")

---@class GiteaActionContext
---@field pr PullRequest|nil
---@field source "main"|"panel"|nil

---@class GiteaActionDef
---@field id string
---@field label string
---@field is_available fun(ctx: GiteaActionContext): boolean, string|nil
---@field run fun(ctx: GiteaActionContext, done: fun(result: PullsActionResult|nil, err: string|nil))

---@param ctx GiteaActionContext
---@return boolean
local function has_pr(ctx)
	return ctx.pr ~= nil and ctx.pr.id ~= nil
end

---@param ctx GiteaActionContext
---@return string
local function repo_slug(ctx)
	return tostring((ctx.pr or {}).repo_full_name or "")
end

---@type GiteaActionDef[]
local ACTIONS = {
	{
		id = "close",
		label = "Close PR",
		is_available = function(ctx)
			if not has_pr(ctx) or ctx.pr == nil then
				return false, "No PR selected"
			end
			if repo_slug(ctx) == "" then
				return false, "Missing repository info"
			end
			local s = tostring(ctx.pr.state or ""):lower()
			if s ~= "open" and s ~= "draft" then
				return false, "PR is not open"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			if pr == nil then
				done(nil, "No PR selected")
				return
			end

			vim.ui.input({
				prompt = string.format("Close PR #%s? [y/N]: ", tostring(pr.id or "")),
			}, function(input)
				if input == nil then
					done({ changed_pr = false, message = "Close cancelled" }, nil)
					return
				end
				local normalized = vim.trim(tostring(input)):lower()
				if normalized ~= "y" and normalized ~= "yes" then
					footer.notify("info", "Close cancelled")
					done({ changed_pr = false, message = "Close cancelled" }, nil)
					return
				end

				footer.notify("loading", "Closing PR...")
				local slug = repo_slug(ctx)
				local endpoint = string.format("repos/%s/pulls/%s", slug, tostring(pr.id))
				cli.api("PATCH", endpoint, { state = "closed" }, function(_, err)
					if err then
						footer.notify("error", string.format("Close failed: %s", tostring(err)))
						done(nil, tostring(err))
						return
					end
					footer.notify("success", "PR closed", 1200)
					done({ changed_pr = true, message = "Closed" }, nil)
				end)
			end)
		end,
	},
	{
		id = "reopen",
		label = "Reopen PR",
		is_available = function(ctx)
			if not has_pr(ctx) or ctx.pr == nil then
				return false, "No PR selected"
			end
			if repo_slug(ctx) == "" then
				return false, "Missing repository info"
			end
			local s = tostring(ctx.pr.state or ""):lower()
			if s ~= "declined" then
				return false, "PR is not closed"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			if pr == nil then
				done(nil, "No PR selected")
				return
			end

			footer.notify("loading", "Reopening PR...")
			local slug = repo_slug(ctx)
			local endpoint = string.format("repos/%s/pulls/%s", slug, tostring(pr.id))
			cli.api("PATCH", endpoint, { state = "open" }, function(_, err)
				if err then
					footer.notify("error", string.format("Reopen failed: %s", tostring(err)))
					done(nil, tostring(err))
					return
				end
				footer.notify("success", "PR reopened", 1200)
				done({ changed_pr = true, message = "Reopened" }, nil)
			end)
		end,
	},
	{
		id = "merge",
		label = "Merge PR",
		is_available = function(ctx)
			if not has_pr(ctx) or ctx.pr == nil then
				return false, "No PR selected"
			end
			if repo_slug(ctx) == "" then
				return false, "Missing repository info"
			end
			local s = tostring(ctx.pr.state or ""):lower()
			if s ~= "open" and s ~= "draft" then
				return false, "PR is not open"
			end
			local raw = type(ctx.pr._raw) == "table" and ctx.pr._raw or {}
			if raw.mergeable == false then
				return false, "PR is not mergeable"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			if pr == nil then
				done(nil, "No PR selected")
				return
			end

			local strategies = { "merge", "rebase", "squash" }
			vim.ui.select(strategies, {
				prompt = string.format("Merge strategy for PR #%s:", tostring(pr.id or "")),
				kind = "atlas_gitea_merge_strategy",
			}, function(strategy)
				if strategy == nil then
					done({ changed_pr = false, message = "Merge cancelled" }, nil)
					return
				end

				vim.ui.input({
					prompt = string.format("Confirm %s merge PR #%s? [y/N]: ", strategy, tostring(pr.id or "")),
				}, function(input)
					if input == nil then
						done({ changed_pr = false, message = "Merge cancelled" }, nil)
						return
					end
					local normalized = vim.trim(tostring(input)):lower()
					if normalized ~= "y" and normalized ~= "yes" then
						footer.notify("info", "Merge cancelled")
						done({ changed_pr = false, message = "Merge cancelled" }, nil)
						return
					end

					footer.notify("loading", "Merging PR...")
					local slug = repo_slug(ctx)
					local endpoint = string.format("repos/%s/pulls/%s/merge", slug, tostring(pr.id))
					local style_map = { merge = "merge", rebase = "rebase", squash = "squash" }
					cli.api("POST", endpoint, { Do = style_map[strategy] or "merge" }, function(_, err)
						if err then
							footer.notify("error", string.format("Merge failed: %s", tostring(err)))
							done(nil, tostring(err))
							return
						end
						footer.notify("success", "Merge succeeded", 1200)
						done({ changed_pr = true, message = "Merged" }, nil)
					end)
				end)
			end)
		end,
	},
	{
		id = "open_browser",
		label = "Open in Browser",
		is_available = function(ctx)
			if not has_pr(ctx) or ctx.pr == nil then
				return false, "No PR selected"
			end
			local url = type(ctx.pr.link) == "table" and tostring(ctx.pr.link.html or "") or ""
			if url == "" then
				return false, "No URL available"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			if pr == nil then
				done(nil, "No PR selected")
				return
			end
			local url = type(pr.link) == "table" and tostring(pr.link.html or "") or ""
			if url == "" then
				done(nil, "No URL available")
				return
			end
			vim.ui.open(url)
			footer.notify("info", "Opened in browser")
			done({ changed_pr = false, message = "Opened in browser" }, nil)
		end,
	},
	{
		id = "copy_url",
		label = "Copy URL",
		is_available = function(ctx)
			if not has_pr(ctx) or ctx.pr == nil then
				return false, "No PR selected"
			end
			local url = type(ctx.pr.link) == "table" and tostring(ctx.pr.link.html or "") or ""
			if url == "" then
				return false, "No URL available"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			if pr == nil then
				done(nil, "No PR selected")
				return
			end
			local url = type(pr.link) == "table" and tostring(pr.link.html or "") or ""
			if url == "" then
				done(nil, "No URL available")
				return
			end
			vim.fn.setreg("+", url)
			footer.notify("success", "Copied URL to clipboard", 1200)
			done({ changed_pr = false, message = "Copied URL" }, nil)
		end,
	},
	{
		id = "checkout",
		label = "Checkout PR branch",
		is_available = function(ctx)
			if not has_pr(ctx) or ctx.pr == nil then
				return false, "No PR selected"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			if pr == nil then
				done(nil, "No PR selected")
				return
			end
			footer.notify("loading", string.format("Checking out PR #%s", tostring(pr.id or "")))
			checkout.checkout_pr(pr, function(_, err)
				vim.schedule(function()
					if err then
						footer.notify("error", string.format("Checkout failed: %s", tostring(err)))
						done(nil, tostring(err))
						return
					end
					footer.notify("success", string.format("Checked out PR #%s", tostring(pr.id or "")))
					done({ changed_pr = false, message = "Checkout done" }, nil)
				end)
			end)
		end,
	},
}

---@param ctx GiteaActionContext
---@return GiteaActionDef[]
function M.available(ctx)
	local out = {}
	for _, action in ipairs(ACTIONS) do
		local ok, _ = action.is_available(ctx)
		if ok then
			table.insert(out, action)
		end
	end
	return out
end

---@param id string
---@return GiteaActionDef|nil
function M.find(id)
	for _, action in ipairs(ACTIONS) do
		if action.id == id then
			return action
		end
	end
	return nil
end

return M
