return {
  "nvim-neo-tree/neo-tree.nvim",
  keys = {
    { "<C-b>", "<cmd>Neotree toggle<cr>", desc = "Toggle Neo-tree" },
  },
  opts = {
    window = {
      mappings = {
        Y = function(state)
          local node = state.tree:get_node()
          local path = node:get_id()
          vim.fn.setreg("+", path)
          vim.notify("Copied: " .. path, vim.log.levels.INFO)
        end,
      },
    },
  },
}
