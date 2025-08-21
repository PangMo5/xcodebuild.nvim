---@mod xcodebuild.integrations.snacks-explorer snacks.nvim Explorer Integration
---@brief [[
---This module integrates with `snacks.nvim` Explorer to keep the Xcode project
---in sync when files or folders are created, moved/renamed, copied, or deleted
---from the Explorer UI.
---
---It hooks Snacks Explorer actions (add/rename/move/copy/delete) directly and
---updates the project accordingly.
---
---The integration is enabled only if the current working directory contains
---the project configuration (|xcodebuild.project.config|).
---
---You can disable or configure the integration in |xcodebuild.config|.
---
---This feature requires `Xcodeproj` to be installed (|xcodebuild.requirements|).
---
---See:
---  |xcodebuild.project-manager|
---  https://github.com/folke/snacks.nvim
---  https://github.com/wojciech-kulik/xcodebuild.nvim/wiki/Integrations#-file-tree-integration
---
---@brief ]]

local M = {}
local installed = false

local function normalize_path(path)
  if type(path) ~= "string" or path == "" then
    return path
  end
  local p = path
  if vim.fs and vim.fs.normalize then
    p = vim.fs.normalize(p)
  end
  if #p > 1 then
    p = p:gsub("/+$", "")
  end
  return p
end

local function is_dir(path)
  return vim.fn.isdirectory(path) == 1
end

---Sets up the integration with `snacks.nvim` Explorer.
---@see xcodebuild.project-manager
function M.setup()
  local cfg = require("xcodebuild.core.config").options.integrations.snacks_explorer
  if installed or not (cfg and cfg.enabled) then
    return
  end

  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    return
  end

  local projectManagerConfig = require("xcodebuild.core.config").options.project_manager
  local projectManager = require("xcodebuild.project.manager")
  local projectConfig = require("xcodebuild.project.config")
  local cwd = vim.fn.getcwd()

  local function is_project_file(path)
    return (projectConfig.is_app_configured() or projectConfig.is_library_configured()) and vim.startswith(path, cwd)
  end

  local function should_update_project(path)
    return path and is_project_file(path) and projectManagerConfig.should_update_project(path)
  end

  -- Wrap rename so both rename and move actions are tracked
  local rename = require("snacks.rename")
  local orig_rename = rename.rename_file
  rename.rename_file = function(opts)
    opts = opts or {}
    local orig_cb = opts.on_rename
    opts.on_rename = function(to, from, ok)
      to = normalize_path(to)
      from = normalize_path(from)
      if orig_cb then
        pcall(orig_cb, to, from, ok)
      end
      if ok and (should_update_project(from) or should_update_project(to)) then
        if is_dir(to) then
          projectManager.move_or_rename_group(from, to)
        else
          projectManager.move_file(from, to)
        end
      end
    end
    return orig_rename(opts)
  end

  -- Wrap copy helpers
  local util = require("snacks.picker.util")
  local orig_copy_path = util.copy_path
  util.copy_path = function(from, to)
    to = normalize_path(to)
    local ret = orig_copy_path(from, to)
    if should_update_project(to) then
      if is_dir(to) then
        -- Copy directory support: add group and recursively add files.
        projectManager.add_group(to)
        local function add_files_recursively(root)
          local files = {}
          for name, t in vim.fs.dir(root) do
            local path = root .. "/" .. name
            if t == "directory" then
              add_files_recursively(path)
            else
              table.insert(files, path)
            end
          end
          if #files > 0 then
            local co = coroutine.create(function(co)
              for _, file in ipairs(files) do
                if should_update_project(file) and not is_dir(file) then
                  vim.schedule(function()
                    projectManager.add_file(file, function()
                      coroutine.resume(co, co)
                    end, { createGroups = true })
                  end)
                  coroutine.yield()
                end
              end
            end)
            coroutine.resume(co, co)
          end
        end
        add_files_recursively(to)
      else
        projectManager.add_file(to, nil, { createGroups = true })
      end
    end
    return ret
  end

  local orig_copy = util.copy
  util.copy = function(paths, dir)
    dir = normalize_path(dir)
    local ret = orig_copy(paths, dir)
    if type(paths) == "table" and dir then
      for _, path in ipairs(paths) do
        local name = vim.fn.fnamemodify(path, ":t")
        local to = normalize_path(vim.fn.fnamemodify(dir .. "/" .. name, ":p"))
        if should_update_project(to) and not is_dir(to) then
          projectManager.add_file(to, nil, { createGroups = true })
        end
      end
    end
    return ret
  end

  -- Override add & delete actions to also update Xcode project
  local ActionsMod = require("snacks.explorer.actions")
  local A = ActionsMod.actions
  local Tree = require("snacks.explorer.tree")
  local uv = vim.uv or vim.loop

  A.explorer_add = function(picker)
    Snacks.input({
      prompt = 'Add a new file or directory (directories end with a "/")',
    }, function(value)
      if not value or value:find("^%s$") then
        return
      end
      local dir = normalize_path(picker:dir())
      local path = normalize_path(vim.fn.fnamemodify(dir .. "/" .. value, ":p"))
      local is_file = value:sub(-1) ~= "/"
      local target_dir = is_file and vim.fs.dirname(path) or path
      if is_file and uv.fs_stat(path) then
        Snacks.notify.warn("File already exists:\n- `" .. path .. "`")
        return
      end
      vim.fn.mkdir(target_dir, "p")
      if is_file then
        local f = io.open(path, "w")
        if f then
          f:close()
        end
      end
      Tree:open(target_dir)
      Tree:refresh(target_dir)
      ActionsMod.update(picker, { target = path })

      local proj_path = is_file and path or target_dir
      if should_update_project(proj_path) then
        if is_file then
          projectManager.add_file(path, nil, { createGroups = true })
        else
          projectManager.add_group(target_dir)
        end
      end
    end)
  end

  A.explorer_del = function(picker)
    local paths = vim.tbl_map(require("snacks.picker.util").path, picker:selected({ fallback = true }))
    if #paths == 0 then
      return
    end
    local types = {}
    for _, p in ipairs(paths) do
      types[p] = (vim.fn.isdirectory(p) == 1) and "directory" or "file"
    end
    local what = #paths == 1 and vim.fn.fnamemodify(paths[1], ":p:~:.") or (#paths .. " files")
    ActionsMod.confirm("Delete " .. what .. "?", function()
      for _, path in ipairs(paths) do
        local ok, err = pcall(vim.fn.delete, path, "rf")
        if ok then
          Snacks.bufdelete({ file = path, force = true })
        else
          Snacks.notify.error("Failed to delete `" .. path .. "`:\n- " .. err)
        end
        Tree:refresh(vim.fs.dirname(path))

        if should_update_project(path) then
          if types[path] == "directory" then
            projectManager.delete_group(path)
          else
            projectManager.delete_file(path)
          end
        end
      end
      picker.list:set_selected() -- clear selection
      ActionsMod.update(picker)
    end)
  end

  installed = true
end

return M
