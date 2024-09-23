local M = {}

M.LSP_NOT_ATTACHED = 'CONNECTION_NOT_ATTEMPTED'
M.NOT_READY = 'NOT_READY'
M.READY = 'READY'

M._status_by_buffer = {}

M.get_status_by_buffer = function(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if M._status_by_buffer[bufnr] then
    return M._status_by_buffer[bufnr]
  end
  return M.LSP_NOT_ATTACHED
end

M.on_attach = function(bufnr)
  if not M._status_by_buffer[bufnr] then
    M._status_by_buffer[bufnr] = M.NOT_READY
  end
end


--- Options for the plugin.
---@class LspNotifyConfig
local options = {
  --- Function to be used for notifies.
  --- Best works if `vim.notify` is already overwritten by `require('notify').
  --- If no, you can manually pass `= require('notify')` here.
  notify = vim.notify,

  --- Exclude by client name.
  excludes = {},

  -- Function to call when LSP client is ready
  on_lsp_ready = function(bufnr) end,

  --- Icons.
  --- Can be set to `= false` to disable.
  ---@type {spinner: string[] | false, done: string | false} | false
  icons = {
    --- Spinner animation frames.
    --- Can be set to `= false` to disable only spinner.
    spinner = { '⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷' },
    --- Icon to show when done.
    --- Can be set to `= false` to disable only spinner.
    done = '✓'
  },
  --- Client message timeout in ms
  client_timeout = 1000,
  --- Task message timeout in ms
  task_timeout = 2000,
}

--- Whether current notification system supports replacing notifications.
--- Will be `true` if `nvim-notify` handles notifications, `false` if `cmdline`.
local supports_replace = false

--- Check if current notification system supports replacing notifications.
---@return boolean suppors
local function check_supports_replace()
  local n = options.notify(
    'lsp notify: test replace support',
    vim.log.levels.DEBUG,
    {
      hide_from_history = true,
      on_open = function(window)
        -- If window is hidden, `nvim-notify` prints errors
        -- This shrinks notifications and puts it in a corner where it will not be seen
        vim.api.nvim_win_set_buf(window, vim.api.nvim_create_buf(false, true))
        vim.api.nvim_win_set_config(
          window, {
            width = 1,
            height = 1,
            border = 'none',
            relative = 'editor',
            row = 0,
            col = 0
          }
        )
      end,
      timeout = 1,
      animate = false
    }
  )
  local supports = pcall(options.notify, 'lsp notify: test replace support', vim.log.levels.DEBUG, { replace = n })
  return supports
end

---@class BaseLspTask
local BaseLspTask = {
  ---@type string?
  title = '',
  ---@type string?
  message = '',
  ---@type number?
  percentage = nil
}

---@param title string
---@param message string
---@return BaseLspTask
function BaseLspTask.new(title, message)
  local self = vim.deepcopy(BaseLspTask)
  self.title = title
  self.message = message
  return self
end

function BaseLspTask:format()
  return (
    ('  ')
    .. (string.format(
      '%-5s',
      self.percentage and self.percentage .. '%' or ''
    ))
    .. (self.title or '')
    .. (self.title and self.message and ' - ' or '')
    .. (self.message or '')
  )
end

---@class BaseLspClient
local BaseLspClient = {
  name = '',
  ---@type {any: BaseLspTask}
  tasks = {}
}

---@param name string
---@return BaseLspClient
function BaseLspClient.new(name)
  local self = vim.deepcopy(BaseLspClient)
  self.name = name
  return self
end

---@return integer
function BaseLspClient:count_tasks()
  local count = 0
  for _ in pairs(self.tasks) do
    count = count + 1
  end
  return count
end

function BaseLspClient:kill_task(task_id)
  self.tasks[task_id] = nil
end

function BaseLspClient:format()
  local tasks = ''
  for _, t in pairs(self.tasks) do
    tasks = tasks .. t:format() .. '\n'
  end

  return (
    (self.name)
    .. ('\n')
    .. (tasks ~= '' and tasks:sub(1, -2) or '  Complete')
  )
end

---@class BaseLspNotification
local BaseLspNotification = {
  spinner = 1,
  ---@type {integer: BaseLspClient}
  clients = {},
  notification = nil,
  window = nil
}

---@return BaseLspNotification
function BaseLspNotification:new()
  return vim.deepcopy(BaseLspNotification)
end

---@return integer
function BaseLspNotification:count_clients()
local count = 0
  for _ in pairs(self.clients) do
    count = count + 1
  end
  return count
end

function BaseLspNotification:notification_start()
  self.notification = options.notify(
    '',
    vim.log.levels.INFO,
    {
      title = 'LSP',
      icon = (options.icons and options.icons.spinner and options.icons.spinner[1]) or nil,
      timeout = false,
      hide_from_history = false,
      on_open = function(window)
        self.window = window
      end
    }
  )
  if not supports_replace then
    -- `options.notify` will not assign `self.notification` if can't be replaced,
    -- so do it manually here
    self.notification = true
  end
end

function BaseLspNotification:notification_progress()
  local message = self:format()
  local message_lines = select(2, message:gsub('\n', '\n'))

  if supports_replace then
    -- Can reuse same notification
    self.notification = options.notify(
      message,
      vim.log.levels.INFO,
      {
        replace = self.notification,
        hide_from_history = false,
      }
    )
    if self.window then
      -- Update height because `nvim-notify` notifications don't do it automatically
      -- Can cover other notifications
      vim.api.nvim_win_set_height(
        self.window,
        3 + message_lines
      )
    end
  else
    -- Can't reuse same notification
    -- Print it line-by-line to not trigger 'Press ENTER or type command to continue'
    for line in message:gmatch('[^\r\n]+') do
      options.notify(
        line,
        vim.log.levels.INFO
      )
    end
  end
end

function BaseLspNotification:notification_end()
  options.notify(
    self:format(),
    vim.log.levels.INFO,
    {
      replace = self.notification,
      icon = options.icons and options.icons.done or nil,
      timeout = 1000
    }
  )
  if self.window then
    -- Set the height back to the smallest notification size
    vim.api.nvim_win_set_height(self.window, 3)
  end

  -- Clean up and reset
  self.notification = nil
  self.spinner = nil
  self.window = nil
end

function BaseLspNotification:update()
  if not self.notification then
    self:notification_start()
    self.spinner = 1
    self:spinner_start()
  elseif self:count_clients() > 0 then
    self:notification_progress()
  elseif self:count_clients() == 0 then
    self:notification_end()
  end
end

function BaseLspNotification:schedule_kill_task(client_id, task_id)
  -- Wait a bit before hiding the task to show that it's complete
  vim.defer_fn(function()
    if not self.clients[client_id] then
      return
    end

    local client = self.clients[client_id]
    client:kill_task(task_id)
    self:update()

    if client:count_tasks() == 0 then
      -- Wait a bit before hiding the client to show that its tasks are complete
      vim.defer_fn(function()
        if client:count_tasks() == 0 then
          -- Make sure we don't hide a client notification if a task appeared in down time
          self.clients[client_id] = nil
          self:update()
        end
      end, options.client_timeout)
    end
  end, options.task_timeout)
end

function BaseLspNotification:format()
  local clients = ''
  for _, c in pairs(self.clients) do
    clients = clients .. c:format() .. '\n'
  end

  return clients ~= '' and clients:sub(1, -2) or 'Complete'
end

function BaseLspNotification:spinner_start()
  if self.spinner and options.icons and options.icons.spinner then
    self.spinner = (self.spinner % #options.icons.spinner) + 1

    if supports_replace then
      -- Don't spam spinner updates if notification can't be replaced
      self.notification = options.notify(
        nil,
        nil,
        {
          hide_from_history = true,
          icon = options.icons.spinner[self.spinner],
          replace = self.notification,
        }
      )
    end

    -- Trigger new spinner frame
    vim.defer_fn(function()
      self:spinner_start()
    end, 100)
  end
end

local notification = BaseLspNotification:new()

local function handle_progress(_err, response, ctx)
  local value = response.value
  local client_id = ctx.client_id
  local client_name = vim.lsp.get_client_by_id(client_id).name

  if options.excludes[client_name] then
    return
  end

  -- Get client info from notification or generate it
  if not notification.clients[client_id] then
    notification.clients[client_id] = BaseLspClient.new(client_name)
  end
  local client = notification.clients[client_id]

  local task_id = response.token

  -- Get task info from notification or generate it
  if not client.tasks[task_id] then
    client.tasks[task_id] = BaseLspTask.new(value.title, value.message)
  end
  local task = client.tasks[task_id]

  local client_buffers = vim.lsp.get_buffers_by_client_id(client_id)

  if value.kind == 'report' then
    for _, bufnr in ipairs(client_buffers) do
      M._status_by_buffer[bufnr] = M.NOT_READY
    end

    -- Task update
    task.message = value.message
    task.percentage = value.percentage
  elseif value.kind == 'end' then
    for _, bufnr in ipairs(client_buffers) do
      local first_fire = M.get_status_by_buffer(bufnr) ~= M.READY
      M._status_by_buffer[bufnr] = M.READY
      if first_fire then
        options.on_lsp_ready(bufnr)
      end
    end

    -- Task end
    task.message = value.message or 'Complete'
    notification:schedule_kill_task(client_id, task_id)
  end

  -- Redraw notification
  notification:update()
end

local function handle_sync(_err, response, ctx)
  local client_id = ctx.client_id
  local client_name = vim.lsp.get_client_by_id(client_id).name

  if options.excludes[client_name] then
    return
  end

  if not response or not response.fileStatuses then
    return
  end

  -- Get client info from notification or generate it
  if not notification.clients[client_id] then
    notification.clients[client_id] = BaseLspClient.new(client_name)
  end
  local client = notification.clients[client_id]

  local client_buffers = vim.lsp.get_buffers_by_client_id(client_id)

  for _, bufnr in ipairs(client_buffers) do
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local basename = vim.fs.basename(bufname)
    local file_status = response.fileStatuses[bufname]

    if file_status then
      local task_id = bufname

      -- Get task info from notification or generate it
      if not client.tasks[task_id] then
        client.tasks[task_id] = BaseLspTask.new(basename, '')
      end
      local task = client.tasks[task_id]

      -- Ready
      if file_status.kind == 1 then
        local first_fire = M.get_status_by_buffer(bufnr) ~= M.READY
        M._status_by_buffer[bufnr] = M.READY

        if first_fire then
          options.on_lsp_ready(bufnr)
        end

        task.message = 'Complete'
        notification:schedule_kill_task(client_id, task_id)
      else
        task.message = file_status.statusMessage
      end
    else
      M._status_by_buffer[bufnr] = M.LSP_NOT_ATTACHED
    end
  end

  -- Redraw notification
  notification:update()
end

local function handle_message(_err, method, params, _client_id)
  -- Table from LSP severity to VIM severity.
  local severity = {
    vim.log.levels.ERROR,
    vim.log.levels.WARN,
    vim.log.levels.INFO,
    vim.log.levels.INFO, -- Map both `hint` and `info` to `info`
  }
  options.notify(method.message, severity[params.type], { title = 'LSP' })
end

-- Helper to chain multiple functions
local chain_fn = function(fn1, fn2)
  return function(...)
    fn1(...)
    fn2(...)
  end
end

local function init()
  -- If there is already a handler, execute it too
  if vim.lsp.handlers['$/progress'] then
    vim.lsp.handlers['$/progress'] = chain_fn(vim.lsp.handlers['$/progress'], handle_progress)
  else
    vim.lsp.handlers['$/progress'] = handle_progress
  end

  -- If there is already a handler, execute it too
  if vim.lsp.handlers['window/showMessage'] then
    vim.lsp.handlers['window/showMessage'] = chain_fn(vim.lsp.handlers['window/showMessage'], handle_message)
  else
    vim.lsp.handlers['window/showMessage'] = handle_message
  end

  -- If there is already a handler, execute it too
  if vim.lsp.handlers['$/syncResponse'] then
    vim.lsp.handlers['$/syncResponse'] = chain_fn(vim.lsp.handlers['$/syncResponse'], handle_sync)
  else
    vim.lsp.handlers['$/syncResponse'] = handle_sync
  end
end

---@param opts LspNotifyConfig? Configuration.
M.setup = function(opts)
  options = vim.tbl_deep_extend('force', options, opts or {})
  supports_replace = check_supports_replace()

  init()
end

return M
