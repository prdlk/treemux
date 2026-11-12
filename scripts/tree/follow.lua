-- Follow the main pane's directory in the sidebar nvim. watch_and_update.sh
-- calls these over `nvim --server <addr> --remote-expr` (see tree_call
-- there): a ~2 ms client call per directory change, where the pynvim helpers
-- this replaces started a Python interpreter (~60 ms) each time.
--
-- Each function returns the tree's root directory afterwards ("" on failure),
-- which the watcher keeps as the side pane root.

local M = {}

--- @param path string
--- @param root string
local function is_relative_to(path, root)
  return root == "/" or path == root or path:sub(1, #root + 1) == root .. "/"
end

local function center()
  if vim.fn.winline() / vim.fn.winheight(0) > 0.5 then vim.cmd "normal! zz" end
end

-- Neo-tree ---------------------------------------------------------------

--- Navigate to `new_root`, reveal `dir`, then expand (`open`) or collapse it.
--- A miss means the directory is filtered: show hidden items and retry.
local function neotree_reveal(new_root, dir, expand)
  local manager = require "neo-tree.sources.manager"
  local filesystem = require "neo-tree.sources.filesystem"
  local fs_cmds = require "neo-tree.sources.filesystem.commands"
  local state = manager.get_state "filesystem"

  local function on_ok()
    local node = state.tree:get_node()
    if not node or node.type ~= "directory" or node.path ~= dir then
      if not state.filtered_items.visible then
        fs_cmds.toggle_hidden(state)
        filesystem.navigate(state, new_root, dir, on_ok)
      end
      return
    end
    if node:is_expanded() ~= expand then fs_cmds.open(state) end
    center()
  end

  filesystem.navigate(state, new_root, dir, on_ok)
end

local function neotree_root() return require("neo-tree.sources.manager").get_state("filesystem").path end

-- nvim-tree --------------------------------------------------------------

--- Reveal `dir` under the current root, else under `side_root`, else make it
--- the root; then open (`expand`) or close it.
local function nvimtree_reveal(dir, side_root, expand)
  local api = require "nvim-tree.api"
  api.tree.find_file(dir)
  local node = api.tree.get_node_under_cursor()
  if node == nil then return end
  if node.absolute_path ~= dir then
    api.tree.change_root(side_root)
    api.tree.find_file(dir)
    node = api.tree.get_node_under_cursor()
    if not node or node.absolute_path ~= dir then
      api.tree.change_root(dir)
      return
    end
  end
  if (node.open and true or false) ~= expand then api.node.open.edit() end
  center()
end

local function nvimtree_root() return require("nvim-tree.api").tree.get_nodes().absolute_path end

-- Entry points -----------------------------------------------------------

--- The tree's filetype once it is up ("" before).
function M.filetype() return vim.bo.filetype end

--- The main pane went somewhere within the tree (or the sidebar just
--- started): reveal and expand `cwd`, keeping the root when it contains `cwd`,
--- else going back to `side_root`, else rooting the tree at `cwd`.
function M.go_random(cwd, side_root)
  if vim.bo.filetype == "neo-tree" then
    local root = neotree_root()
    local new_root = is_relative_to(cwd, root) and root or is_relative_to(cwd, side_root) and side_root or cwd
    neotree_reveal(new_root, cwd, true)
    return new_root
  elseif vim.bo.filetype == "NvimTree" then
    local api = require "nvim-tree.api"
    -- find_file on the root itself would go to its parent
    if nvimtree_root() ~= cwd then
      api.tree.collapse_all()
      nvimtree_reveal(cwd, side_root, true)
    end
    return nvimtree_root()
  end
  return ""
end

--- The main pane went up within the tree: collapse `first_child`, the
--- directory it left.
function M.go_parent(first_child, side_root)
  if vim.bo.filetype == "neo-tree" then
    local root = neotree_root()
    if is_relative_to(first_child, root) or is_relative_to(first_child, side_root) then
      local new_root = is_relative_to(first_child, root) and root or side_root
      neotree_reveal(new_root, first_child, false)
      return new_root
    end
    require("neo-tree.command").execute { action = "focus", position = "current", dir = first_child }
    return first_child
  elseif vim.bo.filetype == "NvimTree" then
    nvimtree_reveal(first_child, side_root, false)
    return nvimtree_root()
  end
  return ""
end

--- The main pane left the tree: root it at `new_root`.
function M.change_root(new_root)
  if vim.bo.filetype == "neo-tree" then
    require("neo-tree.command").execute { action = "focus", position = "current", dir = new_root }
  elseif vim.bo.filetype == "NvimTree" then
    require("nvim-tree.api").tree.change_root(new_root)
  else
    return ""
  end
  return new_root
end

return M
