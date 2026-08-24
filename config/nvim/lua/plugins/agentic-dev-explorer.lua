-- Managed by agentic-dev-setup. File tree on the right, open for `nvim .`.
return {
  {
    "nvim-neo-tree/neo-tree.nvim",
    lazy = false,
    dependencies = {
      "nvim-lua/plenary.nvim",
      "MunifTanjim/nui.nvim",
      "nvim-tree/nvim-web-devicons",
    },
    opts = {
      window = { position = "right" },
      filesystem = {
        hijack_netrw_behavior = "open_default",
      },
    },
  },
  {
    "folke/snacks.nvim",
    optional = true,
    opts = {
      picker = {
        sources = {
          explorer = {
            layout = { layout = { position = "right" } },
          },
        },
      },
    },
  },
}
