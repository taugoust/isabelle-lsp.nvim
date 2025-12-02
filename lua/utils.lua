local M = {}

M.is_windows = vim.loop.os_uname().version:match 'Windows'

---@type fun(isabelle-lsp.Config):string[]
M.init_cmd = function(config)
    local cmd

    if not M.is_windows then
        cmd = {
            config.isabelle_path, 'vscode_server',
            '-o', 'vscode_pide_extensions',
            '-o', 'vscode_html_output=false',
            '-o', 'editor_output_state',
        }

        if config.unicode_symbols_output then
            table.insert(cmd, '-o')
            table.insert(cmd, 'vscode_unicode_symbols_output')
        end

        if config.unicode_symbols_edits then
            table.insert(cmd, '-o')
            table.insert(cmd, 'vscode_unicode_symbols_edits')
        end

        if config.verbose then
            table.insert(cmd, '-v')
        end

        if config.log then
            table.insert(cmd, '-L')
            table.insert(cmd, config.log)
        end
    else -- windows cmd
        local unicode_options_output = ''
        if config.unicode_symbols_output then
            unicode_options_output = ' -o vscode_unicode_symbols_output'
        end

        local unicode_option_edits = ''
        if config.unicode_symbols_edits then
            unicode_option_edits = ' -o vscode_unicode_symbols_edits'
        end

        local verbose = ''
        if config.verbose then
            verbose = ' -v'
        end

        local log = ''
        if config.log then
            log = ' -L ' .. config.log
        end

        cmd = {
            config.sh_path, '-c',
            'cd ' ..
            vim.fs.dirname(config.isabelle_path) ..
            ' && ./isabelle vscode_server -o vscode_pide_extensions -o vscode_html_output=false -o editor_output_state' ..
            unicode_options_output .. unicode_option_edits ..
            verbose .. log,
        }
    end

    return cmd
end

M.init_namespaces = function(config)
    local hl_group_namespace_map = {}
    -- create namespaces for syntax highlighting
    for group, _ in pairs(config.hl_group_map) do
        local id = vim.api.nvim_create_namespace('isabelle-lsp.' .. group)
        hl_group_namespace_map[group] = id
    end

    local output_namespace = vim.api.nvim_create_namespace('isabelle-lsp.dynamic_output')

    return hl_group_namespace_map, output_namespace
end

return M
