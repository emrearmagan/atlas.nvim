---@alias AtlasReviewLayout "side-by-side"|"inline"

---@class AtlasReviewWindow
---@field buf integer
---@field win integer|nil

---@class AtlasReviewDocumentSide
---@field path string
---@field lines string[]

---@class AtlasDiffLineChange
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer

---@class AtlasReviewDocument
---@field status DiffFileStatus
---@field old AtlasReviewDocumentSide
---@field new AtlasReviewDocumentSide
---@field changes AtlasDiffLineChange[]
---@field binary boolean

---@class AtlasReviewView
---@field notify fun(level: "loading"|"success"|"warn"|"error"|"info", message: string, duration?: integer)
---@field register_keymaps fun(actions: AtlasReviewKeymapActions)
---@field task_at_cursor (fun(): PullsComment|nil)|nil

---@class AtlasReviewKeymapActions
---@field active fun(): boolean
---@field toggle_approval (fun())|nil
---@field request_changes (fun())|nil
---@field submit_review (fun())|nil
---@field toggle_task (fun())|nil
---@field toggle_resolved fun(buf: integer)
---@field add_comment fun(buf: integer, pending: boolean)
---@field delete_comment fun(buf: integer)
---@field toggle_thread fun(buf: integer): boolean
---@field toggle_all_threads fun(): boolean
---@field jump_comment fun(buf: integer, direction: 1|-1)
---@field open_in_browser fun(buf: integer)

---@class AtlasReviewSession
---@field tabpage integer
---@field head_revision string
---@field layout AtlasReviewLayout
---@field document AtlasReviewDocument|nil
---@field left AtlasReviewWindow
---@field right AtlasReviewWindow
---@field review AtlasReviewState|nil
---@field notes AtlasReviewNotesState|nil
---@field review_view AtlasReviewView
---@field refresh_ui fun()
---@field closing boolean
