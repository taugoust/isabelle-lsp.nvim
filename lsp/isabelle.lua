local utils = require('utils')

local config = type(vim.g.isabelle_lsp) == 'function' and vim.g.isabelle_lsp() or vim.g.isabelle_lsp or {}

local function get_uri_from_fname(fname)
    return vim.uri_from_fname(vim.fs.normalize(fname))
end

local function find_buffer_by_uri(uri)
    for _, buf in ipairs(vim.fn.getbufinfo({ bufloaded = 1 })) do
        local bufname = vim.fn.bufname(buf.bufnr)
        -- get the full path of the buffer's file
        -- bufname will typically only be the filename
        local fname = vim.fn.fnamemodify(bufname, ":p")
        local bufuri = get_uri_from_fname(fname)

        if bufuri == uri then
            return buf.bufnr
        end
    end
    return nil
end

local function send_request(client, method, payload, callback)
    client.request('PIDE/' .. method, payload, function(err, result)
        if err then
            error(tostring(err))
        end

        callback(result)
    end, 0)
end

local function send_notification(client, method, payload)
    send_request(client, method, payload, function(_) end)
end

-- assumes `client` is the client associated with the current window's buffer
local function caret_update(client)
    local bufnr = vim.api.nvim_get_current_buf()
    local fname = vim.api.nvim_buf_get_name(bufnr)
    local uri = get_uri_from_fname(fname)

    local win = vim.api.nvim_get_current_win()
    local line, col = unpack(vim.api.nvim_win_get_cursor(win))
    -- required becuase win_get_cursor is (1, 0) indexed -.-
    line = line - 1

    -- convert to char index for Isabelle
    local line_s = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
    -- the extra space is so that it still gives us a correct column
    -- even if the cursor is in insert mode at the end of the line
    col = vim.fn.charidx(line_s .. " ", col)

    send_notification(client, 'caret_update', { uri = uri, line = line, character = col })
end

-- may return nil if there are no windows with that buffer
local function get_min_width(bufnr)
    local windows = vim.fn.win_findbuf(bufnr)
    local min_width
    for _, window in ipairs(windows) do
        local width = vim.api.nvim_win_get_width(window)
        if not min_width or min_width < width then
            min_width = width
        end
    end
    return min_width
end

local function set_output_margin(client, size)
    if size then
        -- the `- 8` is for some headroom
        send_notification(client, 'output_set_margin', { margin = size - 8 })
    end
end

local function set_state_margin(client, id, size)
    if size then
        -- the `- 8` is for some headroom
        send_notification(client, 'state_set_margin', { id = id, margin = size - 8 })
    end
end

local function convert_symbols(client, bufnr, text)
    send_request(
        client,
        "symbols_convert_request",
        { text = text, unicode = config.unicode_symbols_edits },
        function(t)
            local lines = {}
            for s in t.text:gmatch("([^\r\n]*)\n?") do
                table.insert(lines, s)
            end
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        end
    )
end

local function apply_decoration(bufnr, hl_group, syn_id, content)
    for _, range in ipairs(content) do
        -- range.range has the following format:
        -- {start_line, start_column, end_line, end_column}
        -- where all values are character indexes, not byte indexes
        local start_line = range.range[1]
        local start_col = range.range[2]
        local end_line = range.range[3]
        local end_col = range.range[4]

        -- convert indexes to byte indexes
        local sline = vim.api.nvim_buf_get_lines(bufnr, start_line, start_line + 1, false)[1]
        start_col = vim.fn.byteidx(sline, start_col)
        local eline = vim.api.nvim_buf_get_lines(bufnr, end_line, end_line + 1, false)[1]
        end_col = vim.fn.byteidx(eline, end_col)

        -- it can happen that one changes the buffer while the LSP sends a decoration message
        -- and then the decorations in the message apply to text that was just deleted
        -- in which case vim.api.nvim_buf_set_extmark fails
        --
        -- thus we use pcall to suppress errors if they occur, as they are disrupting and not of importance
        local _ = pcall(vim.api.nvim_buf_set_extmark, bufnr, syn_id, start_line, start_col,
            { hl_group = hl_group, end_line = end_line, end_col = end_col })
    end
end

local function state_init(client, state_buffers)
    send_request(client, 'state_init', {}, function(result)
        local id = result.state_id

        local new_buf = vim.api.nvim_create_buf(true, true)
        vim.api.nvim_buf_set_name(new_buf, "--STATE-- " .. id)
        vim.api.nvim_set_option_value('filetype', 'isabelle_output', { buf = new_buf })

        vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, {})

        -- place the state window
        vim.api.nvim_open_win(new_buf, false, { split = 'right' })

        local min_width = get_min_width(new_buf)
        set_state_margin(client, id, min_width)

        -- handle resizes
        vim.api.nvim_create_autocmd('WinResized', {
            callback = function(_)
                local min_width2 = get_min_width(new_buf)
                set_state_margin(client, id, min_width2)
            end,
        })

        state_buffers[id] = new_buf
    end)
end

local hl_group_namespace_map, output_namespace = utils.init_namespaces(config)
local cmd = utils.init_cmd(config)

local output_buffer
local state_buffers = {}

---@type vim.lsp.Config
return {
    cmd = cmd,
    filetypes = { 'isabelle' },
    root_markers = { 'ROOT', '.git', '.hg' },
    handlers = {
        ['PIDE/dynamic_output'] = function(_, params, _, _)
            if not output_buffer then return end

            local lines = {}
            -- this regex makes sure that empty lines are still kept
            for s in params.content:gmatch("([^\r\n]*)\n?") do
                table.insert(lines, s)
            end
            vim.api.nvim_buf_set_lines(output_buffer, 0, -1, false, lines)

            -- clear all decorations
            vim.api.nvim_buf_clear_namespace(output_buffer, output_namespace, 0, -1)

            for _, dec in ipairs(params.decorations) do
                local hl_group = config.hl_group_map[dec.type]

                -- if hl_group is nil, it means the hl_group_map doesn't know about this group
                if hl_group == nil then
                    vim.notify("Could not find hl_group " .. dec.type .. ".")
                    goto continue
                end

                -- if hl_group is false, it just means there is no highlighting done for this group
                if hl_group == false then goto continue end

                apply_decoration(output_buffer, hl_group, output_namespace, dec.content)

                ::continue::
            end
        end,
        ['PIDE/decoration'] = function(_, params, _, _)
            local bufnr = find_buffer_by_uri(params.uri)

            if not bufnr then
                vim.notify("Could not find buffer for " .. params.uri .. ".")
                return
            end

            for _, entry in ipairs(params.entries) do
                local syn_id = hl_group_namespace_map[entry.type]
                local hl_group = config.hl_group_map[entry.type]

                -- if id is nil, it means the hl_group_map doesn't know about this group
                if not syn_id then
                    -- in particular, hl_group is nil here too
                    vim.notify("Could not find hl_group " .. entry.type .. ".")
                    goto continue
                end

                -- if hl_group is false, it just means there is no highlighting done for this group
                if not hl_group then goto continue end

                vim.api.nvim_buf_clear_namespace(bufnr, syn_id, 0, -1)
                apply_decoration(bufnr, hl_group, syn_id, entry.content)

                ::continue::
            end
        end,
        ['PIDE/state_output'] = function(_, params, _, _)
            local id = params.id
            local buf = state_buffers[id]

            local lines = {}
            -- this regex makes sure that empty lines are still kept
            for s in params.content:gmatch("([^\r\n]*)\n?") do
                table.insert(lines, s)
            end
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

            -- clear all decorations
            vim.api.nvim_buf_clear_namespace(buf, output_namespace, 0, -1)

            for _, dec in ipairs(params.decorations) do
                local hl_group = config.hl_group_map[dec.type]

                -- if hl_group is nil, it means the hl_group_map doesn't know about this group
                if hl_group == nil then
                    -- in particular, hl_group is nil here too
                    vim.notify("Could not find hl_group " .. dec.type .. ".")
                    goto continue
                end

                -- if hl_group is false, it just means there is no highlighting done for this group
                if hl_group == false then goto continue end

                apply_decoration(buf, hl_group, output_namespace, dec.content)

                ::continue::
            end
        end,
    },
    on_attach = function(client, bufnr)
        vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
            buffer = bufnr,
            callback = function(_)
                caret_update(client)
            end,
        })

        -- only create output buffer if it doesn't exist yet
        -- otherwise reuse it
        if not output_buffer then
            -- create a new scratch buffer for output & state
            output_buffer = vim.api.nvim_create_buf(true, true)
            vim.api.nvim_buf_set_name(output_buffer, "--OUTPUT--")
            vim.api.nvim_set_option_value('filetype', 'isabelle_output', { buf = output_buffer })

            -- set the content of the output buffer
            vim.api.nvim_buf_set_lines(output_buffer, 0, -1, false, {})

            -- place the output window
            if config.vsplit then
                vim.api.nvim_open_win(output_buffer, false, { split = 'right' })
            else
                vim.api.nvim_open_win(output_buffer, false, { split = 'below' })
            end

            -- make the output buffer automatically quit
            -- if it's the last window
            -- TODO doesn't work in many cases
            vim.api.nvim_create_autocmd({ "BufEnter" }, {
                buffer = output_buffer,
                callback = function(_)
                    if #vim.api.nvim_list_wins() == 1 then
                        vim.cmd "quit"
                    end
                end,
            })

            local min_width = get_min_width(output_buffer)
            set_output_margin(client, min_width)
        end

        -- handle resizes of output buffers
        vim.api.nvim_create_autocmd('WinResized', {
            callback = function(_)
                local min_width = get_min_width(output_buffer)
                set_output_margin(client, min_width)
            end,
        })

        -- commands
        vim.api.nvim_buf_create_user_command(bufnr, 'StateInit', function()
            state_init(client, state_buffers)
        end, { desc = 'Open a State Panel' })

        vim.api.nvim_buf_create_user_command(bufnr, 'SymbolsRequest', function()
            send_notification(client, "symbols_request", {})
        end, {})

        vim.api.nvim_buf_create_user_command(bufnr, 'SymbolsConvert', function()
            local text = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local t = table.concat(text, '\n')
            convert_symbols(client, bufnr, t)
        end, { desc = 'Convert Symbols in buffer to Unicode' })
    end,
}
