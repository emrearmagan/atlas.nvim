local M = {}

local client_factory = require("atlas.providers.forge.api.client")
local notifications_factory = require("atlas.providers.forge.api.notifications")
local pagination_factory = require("atlas.providers.forge.api.pagination")

---@alias ForgeProviderId "gitea"|"forgejo"
---@alias ForgeProviderName "Gitea"|"Forgejo"
---@alias ForgeQueryValue string|number|boolean|(string|number|boolean)[]|nil

---@class ForgeRequestContext
---@field action string|nil Human-readable operation name used for the log message.
---@field repo string|nil
---@field branch string|nil
---@field issue_key string|nil
---@field pr_id string|integer|nil
---@field review_id string|integer|nil
---@field pipeline_id string|integer|nil
---@field job_id string|integer|nil

---@class ForgeRequestHandle
---@field job_id integer
---@field cancel fun()

---@class ForgePaginationOpts
---@field page_size integer|nil
---@field max_items integer|nil

---@class ForgeClient
---@field config fun(): AtlasGiteaConfig|AtlasForgejoConfig
---@field get_auth fun(): string, string|nil
---@field base_url fun(): string
---@field hostname fun(): string|nil
---@field cache_ttl fun(): number
---@field get_cache fun(key: string): any|nil, boolean
---@field set_cache fun(key: string, value: any)
---@field clear_cache fun(prefix: string)
---@field get_memory_cache fun(key: string): any|nil, boolean
---@field set_memory_cache fun(key: string, value: any)
---@field delete_memory_cache fun(key: string)
---@field absolute_url fun(value: string|nil): string|nil
---@field url fun(endpoint: string): string
---@field url_encode fun(value: string): string
---@field query fun(values: table<string, ForgeQueryValue>): string
---@field headers fun(): table<string, string>
---@field request fun(method: string, endpoint: string, data: table|nil, on_done: fun(result: any, err: string|nil, status: integer|nil), ctx: ForgeRequestContext|nil): ForgeRequestHandle|nil
---@field request_text fun(method: string, endpoint: string, on_done: fun(result: string|nil, err: string|nil, status: integer|nil), ctx: ForgeRequestContext|nil): ForgeRequestHandle|nil

---@class ForgePagination
---@field fetch_all fun(endpoint: string, params: table<string, any>|nil, opts: ForgePaginationOpts|nil, on_done: fun(values: table[]|nil, err: string|nil), ctx: ForgeRequestContext|nil): AtlasRequestScope

---@class ForgeService : ForgeClient
---@field id ForgeProviderId
---@field name ForgeProviderName
---@field default_host string|nil
---@field fetch_all fun(endpoint: string, params: table<string, any>|nil, opts: ForgePaginationOpts|nil, on_done: fun(values: table[]|nil, err: string|nil), ctx: ForgeRequestContext|nil): AtlasRequestScope
---@field notifications AtlasNotificationsCapability
---@field users AtlasUsersCapability
---@field repository ForgeRepositoriesApi

---@param provider_id ForgeProviderId
---@param provider_name ForgeProviderName
---@param default_host string|nil Host used when `base_url` is not configured.
---@return ForgeService
function M.new(provider_id, provider_name, default_host)
	---@type ForgeService
	local service = client_factory.new(provider_id, provider_name, default_host)
	service.id = provider_id
	service.name = provider_name
	service.default_host = default_host
	service.fetch_all = pagination_factory.new(service).fetch_all
	service.notifications = notifications_factory.new(service)
	service.users = require("atlas.providers.forge.users").new(service)
	service.repository = require("atlas.providers.forge.repositories").new(service)
	return service
end

return M
