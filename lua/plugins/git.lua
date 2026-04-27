return {
  {
    "NeogitOrg/neogit",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "sindrets/diffview.nvim",
      "nvim-telescope/telescope.nvim",
    },
    cmd = "Neogit",
    keys = {
      { "<leader>gs", "<cmd>Neogit<cr>",               desc = "Git Status" },
      { "<leader>gb", "<cmd>Neogit branch<cr>",        desc = "Git Branches" },
    },
    opts = {
      integrations = { diffview = true, telescope = true },
    },
  },
  {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewFileHistory" },
    keys = {
      { "<leader>gd", "<cmd>DiffviewOpen<cr>",         desc = "Diff View" },
      { "<leader>gh", "<cmd>DiffviewFileHistory<cr>",  desc = "File History" },
    },
  },
  {
    "pwntester/octo.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-telescope/telescope.nvim",
    },
    cmd = "Octo",
    keys = {
      { "<leader>gp", "<cmd>Octo pr list<cr>",         desc = "PR List" },
      { "<leader>gc", "<cmd>Octo pr checkout<cr>",     desc = "Checkout PR" },
      { "<leader>gr", "<cmd>Octo repo create<cr>",     desc = "Create Repo" },
      { "<leader>gP", "<cmd>Octo pr create<cr>",       desc = "Create PR" },
    },
    opts = {},
  },
  {
    "cljoly/telescope-repo.nvim",
    dependencies = { "nvim-telescope/telescope.nvim", "nvim-lua/plenary.nvim" },
    event = "VeryLazy",
    config = function()
      require("telescope").load_extension("repo")
    end,
    keys = {
      { "<leader>fp", function()
          require("telescope").extensions.repo.list({ search_dirs = { "~/Documents/GitHub" } })
        end,
        desc = "Local Projects",
      },
      { "<leader>fg", function() require("plugins.gh").pick() end, desc = "GitHub Repos" },
      { "<leader>fw", function() require("plugins.gh").worktrees() end, desc = "Switch Worktree" },
    },
  },
}
