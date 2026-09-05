---@class AtlasNotification
---@field id string
---@field title string
---@field subtitle string|nil
---@field timestamp string|nil  -- ISO8601
---@field icon string|nil
---@field icon_hl string|nil
---@field unread boolean
---@field url string|nil
---@field _raw table|nil

---@class AtlasNotificationsCapability
---@field fetch fun(opts: { force_refresh: boolean|nil }|nil, on_done: fun(notifications: AtlasNotification[]|nil, err: string|nil)): { cancel: fun() }|nil
---@field mark_read fun(id: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil
---@field mark_done fun(id: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil

return {}
