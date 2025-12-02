local M = {}

M.setup = function(user_config)
    ---@type isabelle-lsp.Config | fun():isabelle-lsp.Config | nil
    vim.g.isabelle_lsp = vim.tbl_deep_extend('force', require('defaults'), user_config or {})
end

return M
