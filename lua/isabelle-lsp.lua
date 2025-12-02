local M = {}

--- Merges the given user_config into vim.g.isabelle_lsp.
--- @type fun(user_config: isabelle-lsp.Config)
M.setup = function(user_config)
    --- @type isabelle-lsp.Config
    vim.g.isabelle_lsp = vim.tbl_deep_extend('force', vim.g.isabelle_lsp or {}, user_config or {})
end

return M
