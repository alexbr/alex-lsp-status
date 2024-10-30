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
  --- Works best if `vim.notify` is already overwritten by `require('notify').
  --- If not, you can manually pass `require('notify')` here.
  notify = vim.notify,

  --- Exclude by client name.
  excludes = {},

  --- Function to call when LSP client is ready
  --- @type function bufnr integer
  on_lsp_ready = function(bufnr) end,

  --- Icons.
  --- Can be set to `= false` to disable.
  --- @type {spinner: string[] | false, done: string | false} | false
  icons = {
    --- Spinner animation frames.
    --- Can be set to `= false` to disable only spinner.
    spinner = { '⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷' },
    --- Icon to show when done.
    --- Can be set to `= false` to disable only spinner.
    done = '✓'
  },
  --- Width of the notification window in columns.
  --- @type integer
  window_width = 60,

  --- Client message timeout in ms.
  --- @type integer
  client_timeout = 1000,

  --- Task message timeout in ms.
  --- @type integer
  task_timeout = 2000,
}

--- Whether current notification system supports replacing notifications.
--- Will be `true` if `nvim-notify` handles notifications, `false` if `cmdline`.
local supports_replace = false

--- Check if current notification system supports replacing notifications.
---@return boolean suppors
local function check_supports_replace()
  local notify_options = {
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
  local test_msg = 'lsp notify: test replace support'
  local test_notification = options.notify(test_msg, vim.log.levels.DEBUG, notify_options)
  local supports = pcall(options.notify, test_msg, vim.log.levels.DEBUG, { replace = test_notification })
  return supports
end

---@class BaseLspTask
local BaseLspTask = {
  --- @type string?
  title = '',
  --- @type string?
  message = '',
  --- @type number?
  percentage = nil,
  --- @type integer see vim.log.levels
  level = vim.log.levels.INFO,
  --- @type string
  status = M.LSP_NOT_ATTACHED,
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

function BaseLspTask:get_msg()
  return '  '
      .. (self.percentage and string.format('%-5s', self.percentage .. '%') or '')
      .. (self.title or '')
      .. (self.title and self.message and ' - ' or '')
      .. (self.message or '')
end

--- Update the task with new attributes.
function BaseLspTask:update_task(status, level, message)
  self.status = status
  self.level = level
  self.message = message
end

--- @class BaseLspClient
local BaseLspClient = {
  name = '',
  --- @type {any: BaseLspTask}
  tasks = {}
}

--- @param name string
--- @return BaseLspClient
function BaseLspClient.new(name)
  local self = vim.deepcopy(BaseLspClient)
  self.name = name
  return self
end

--- @return integer
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

function BaseLspClient:get_level()
  local level = vim.log.levels.INFO

  for _, t in pairs(self.tasks) do
    if (t.level and t.level > level) then
      level = t.level
    end
  end

  return level
end

function BaseLspClient:get_lines()
  local lines = { self.name }
  local i = 2
  for _, t in pairs(self.tasks) do
    lines[i] = '  ' .. t:get_msg()
    i = i + 1
  end
  return lines
end

function BaseLspClient:format()
  local tasks = ''
  for _, t in pairs(self.tasks) do
    tasks = tasks .. t:get_msg() .. '\n'
  end

  return
      self.name .. '\n' .. (tasks ~= '' and tasks:sub(1, -2) or '  Complete')
end

--- @class BaseLspNotification
local BaseLspNotification = {
  spinner = 1,
  ---@type {integer: BaseLspClient}
  clients = {},
  notification = nil,
  window = nil
}

--- @return BaseLspNotification
function BaseLspNotification:new()
  return vim.deepcopy(BaseLspNotification)
end

--- @return integer
function BaseLspNotification:count_clients()
  local count = 0
  for _ in pairs(self.clients) do
    count = count + 1
  end
  return count
end

function BaseLspNotification:notification_start()
  self.notification = options.notify(
    'Opening',
    vim.log.levels.INFO,
    {
      title = 'LSP',
      icon = (options.icons and options.icons.spinner and options.icons.spinner[1]) or nil,
      render = 'wrapped-default',
      max_width = options.window_width,
      timeout = false,
      hide_from_history = false,
      on_open = function(window)
        self.window = window
        --vim.api.nvim_win_set_width(self.window, options.window_width)
      end
    }
  )

  if not supports_replace then
    -- `options.notify` will not assign `self.notification` if it can't be replaced,
    -- so do it manually here
    self.notification = true
  end
end

function BaseLspNotification:notification_progress()
  local message_lines = self:get_lines()
  local line_count = 0
  for _, line in pairs(message_lines) do
    line_count = line_count + math.ceil(string.len(line) / options.window_width)
  end

  local message = self:format()
  --local _, line_count = message:gsub('\n', '\n')
  local level = self:get_level()

  if supports_replace then
    -- Can reuse same notification
    local notify_options = {
      replace = self.notification,
      hide_from_history = false,
    }
    self.notification = options.notify(message, level, notify_options)

    if self.window then
      -- Update height because `nvim-notify` notifications don't do it automatically
      -- Can cover other notifications
      vim.api.nvim_win_set_height(self.window, 3 + line_count)
    end
  else
    -- Can't reuse same notification
    -- Print it line-by-line to not trigger 'Press ENTER or type command to continue'
    for line in message:gmatch('[^\r\n]+') do
      options.notify(line, vim.log.levels.INFO)
    end
  end
end

function BaseLspNotification:notification_end()
  local notify_options = {
    replace = self.notification,
    icon = options.icons and options.icons.done or nil,
    timeout = 1000
  }
  options.notify(self:format(), vim.log.levels.INFO, notify_options)

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
  -- Initialize the notification window
  if not self.notification then
    self:notification_start()
    self.spinner = 1
    self:spinner_start()
  end

  if self:count_clients() > 0 then
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

function BaseLspNotification:get_level()
  local level = vim.log.levels.INFO

  for _, c in pairs(self.clients) do
    local client_level = c:get_level()
    if client_level > level then
      level = client_level
    end
  end

  return level
end

function BaseLspNotification:format_message()
  local message = ''
  local message_lines = self:get_lines()
  local line_count = 0
  for _, line in pairs(message_lines) do
    line_count = line_count + 1
    if string.len(line) > options.window_width then
      line_count = line_count + 1
    end
    message = message .. '' .. '\n'
  end
  return line_count, message
end

function BaseLspNotification:get_lines()
  local lines = {}
  local i = 0
  for _, c in pairs(self.clients) do
    local task_lines = c:get_lines()
    for j, line in pairs(task_lines) do
      lines[i + j] = line
    end
  end
  return lines
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
      ---@diagnostic disable-next-line: param-type-mismatch
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

--- Global notification
local notification = BaseLspNotification:new()

--- Get client from notification or create it.
--- @type string client_id
--- @type string client_name
--- @return BaseLspClient
local function get_or_create_client(client_id, client_name)
  if not notification.clients[client_id] then
    notification.clients[client_id] = BaseLspClient.new(client_name)
  end
  return notification.clients[client_id]
end

--- Get task from notification or create it.
--- @type BaseLspClient client
--- @type string task_id
--- @type string title
--- @type string message
--- @return BaseLspTask
local function get_or_create_task(client, task_id, title, message)
  message = message or ''
  if not client.tasks[task_id] then
    client.tasks[task_id] = BaseLspTask.new(title, message)
  end
  return client.tasks[task_id]
end


local function handle_progress(_err, response, ctx)
  local value = response.value
  local client_id = ctx.client_id
  local client_name = vim.lsp.get_client_by_id(client_id).name

  if options.excludes[client_name] then
    return
  end

  local client = get_or_create_client(client_id, client_name)
  local task_id = response.token
  local task = get_or_create_task(client, task_id, value.title, value.message)
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

local function clean_msg(msg)
  msg = msg or ''
  msg, _ = msg:gsub('%[([^]]+)%]%(([^)]+)%)', '%1 %2')
  return msg
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

  local new_client = not notification.clients[client_id]
  local client = get_or_create_client(client_id, client_name)
  local client_buffers = vim.lsp.get_buffers_by_client_id(client_id)

  for _, bufnr in ipairs(client_buffers) do
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local basename = vim.fs.basename(bufname)
    local file_status = response.fileStatuses[bufname]

    if file_status then
      local task_id = bufname
      print(basename .. ': ' .. file_status.statusMessage)
      local file_status_msg = clean_msg(file_status.statusMessage)

      -- Ready
      if file_status.kind == 1 then
        -- TODO get rid of status by buffer, just use the task.status
        local first_fire = not client.tasks[task_id] or client.tasks[task_id].status ~= M.READY
        if first_fire then
          options.on_lsp_ready(bufnr)
        end

        -- TODO: only create task if task state (eg. status) has changed to
        -- avoid regenerating tasks that were killed and have no new meaningful updates
        if new_client or first_fire then
          local task = get_or_create_task(client, task_id, basename)
          task:update_task(M.READY, vim.log.levels.INFO, 'Complete')
          M._status_by_buffer[bufnr] = M.READY

          -- Schedule task message removal
          notification:schedule_kill_task(client_id, task_id)
        end
      elseif file_status.kind == 3 then
        -- Warning
        local task = get_or_create_task(client, task_id, basename)
        task:update_task(M.NOT_READY, vim.log.levels.WARN, file_status_msg)
        M._status_by_buffer[bufnr] = M.NOT_READY
      elseif file_status.kind == 4 then
        -- Error
        local task = get_or_create_task(client, task_id, basename)
        task:update_task(M.NOT_READY, vim.log.levels.ERROR, file_status_msg)
        M._status_by_buffer[bufnr] = M.NOT_READY
      else
        local task = get_or_create_task(client, task_id, basename)
        task:update_task(M.NOT_READY, vim.log.levels.INFO, file_status_msg)
        M._status_by_buffer[bufnr] = M.NOT_READY
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
  supports_replace = check_supports_replace()

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
  init()
end

return M
