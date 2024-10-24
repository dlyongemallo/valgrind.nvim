local M = {}

function M.setup(opts)
    opts = opts or {}

    vim.api.nvim_create_user_command("Valgrind", M.run_valgrind, { nargs = 1 })
    vim.api.nvim_create_user_command("ValgrindLoadXml", M.valgrind_load_xml, { nargs = 1 })
    vim.api.nvim_create_user_command("SanitizerLoadLog", M.sanitizer_load_log, { nargs = 1 })
end

local function starts_with(str, start)
    return str:sub(1, #start) == start
end

local summarize_rw = function(rw)
    local has_read = false
    local has_write = false
    for k, _ in pairs(rw) do
        if k == "read" then
            has_read = true
        elseif k == "write" then
            has_write = true
        end
        if has_read and has_write then
            return "read/write"
        end
    end
    if has_read then
        return "read"
    elseif has_write then
        return "write"
    else
        return "unknown operation"
    end
end

local summarize_table_keys = function(t, show_only_first_entry, sort_by_numeric_value)
    show_only_first_entry = show_only_first_entry or false
    sort_by_numeric_value = sort_by_numeric_value or false

    local sorted_t = {}
    local n = 0
    for k, _ in pairs(t) do
        if sort_by_numeric_value then
            k = tonumber(k)
        end
        table.insert(sorted_t, k)
        n = n + 1
    end
    table.sort(sorted_t)
    if n == 1 then
        return sorted_t[1]
    elseif show_only_first_entry then
        return sorted_t[1] .. "/..."
    else
        return table.concat(sorted_t, '/')
    end
end

local summarize_links = function(link)
    local sorted_links = {}
    for k, _ in pairs(link) do
        table.insert(sorted_links, k)
    end
    table.sort(sorted_links)
    local summary = ""
    local prev_filename = ""
    local has_end = false
    for _, full_link in pairs(sorted_links) do
        if full_link == "END" then
            has_end = true
        else
            local filename, line_number = string.match(full_link, "^(.*):(%d+)$")
            line_number = line_number:match("^0*(%d+)$") -- remove leading zeros used for sorting
            if filename == prev_filename then
                summary = summary .. "," .. line_number
            else
                if prev_filename ~= "" then
                    summary = summary .. "/"
                end
                summary = summary .. filename .. ":" .. line_number
                prev_filename = filename
            end
        end
    end
    if has_end then
        if summary ~= "" then
            summary = summary .. "/"
        end
        summary = summary .. "END"
    end
    return summary
end

local populate_link = function(link, prev_target)
    if prev_target then
        link["->" .. prev_target] = true
    else
        link['END'] = true
    end

end

-- TODO: Investigate why this doesn't work on calls subsequent to the first call.
M.extract_valgrind_error = function(xml_file, error_file)
    -- TODO: Use luarocks for this. See: https://github.com/theHamsta/nvim_rocks
    local xml2lua = require("valgrind.lib.xml2lua.xml2lua")
    local handler = require("valgrind.lib.xml2lua.xmlhandler.tree")

    -- TODO: Check that the following supports valgrind tools other than memcheck and helgrind.
    local parser = xml2lua.parser(handler)
    parser:parse(xml2lua.loadFile(xml_file))

    -- TODO: Clean up the code.
    local error_file_handle = io.open(error_file, "w")
    if not error_file_handle then
        print("Failed to open error file: " .. error_file)
        return
    end
    local error = handler.root.valgrindoutput
    if error.error and #error.error > 1 then
        error = error.error
    end
    local general_map = {}
    local data_race_map = {}
    -- TODO: Show progress to the user somehow.
    local num_errors = 0
    for _, e in pairs(error) do
        if not e.kind then goto not_error_continue end
        if not e.stack then goto not_error_continue end
        local stack = e
        if stack.stack and #stack.stack > 1 then
           stack = stack.stack
        end
        for _, s in pairs(stack) do
            if not s.frame then goto not_frame_continue end
            local frame = s
            if frame.frame and #frame.frame > 1 then
                frame = frame.frame
            end
            local target
            local prev_target
            for _, f in pairs(frame) do
                if not f.dir or not f.file then goto not_file_continue end
                if not starts_with(f.dir, "/home/") then goto not_file_continue end -- TODO: Use git_root instead!
                -- Add leading zeroes to line numbers for sorting.
                target = f.dir .. "/" .. f.file .. ":" .. string.format("%06d", f.line or "1")
                local message = ""
                if e.kind then
                    message = message .. "[" .. e.kind .. "] "
                end
                if e.what then
                    message = message .. e.what
                elseif e.xwhat then
                    message = message .. e.xwhat.text
                end

                local key, rw, size, addr, thr
                rw, size, addr, thr = string.match(message,
                        "^(.*):(%d+):%[Race%] Possible data race during (.*) of size (%d+) at (0x%x+) by thread (#%d+)")
                if rw then
                    -- TODO: This should probably be controlled by a "compactify" option.
                    if not data_race_map[key] then
                        data_race_map[key] = { rw = {}, size = {}, addr = {}, thr = {}, link = {} }
                    end
                    data_race_map[key].rw[rw] = true
                    data_race_map[key].size[size] = true
                    data_race_map[key].addr[addr] = true
                    data_race_map[key].thr[thr] = true
                    populate_link(data_race_map[key].link, prev_target)

                else
                    -- Other general messages.
                    key = target .. ":" .. message
                    if not general_map[key] then
                        general_map[key] = { link = {} }
                    end
                    populate_link(general_map[key].link, prev_target)

                end
                prev_target = string.match(target, ".*/(.+)")
                ::not_file_continue::
            end
            ::not_frame_continue::
        end
        num_errors = num_errors + 1
        ::not_error_continue::
    end

    local output_table = {}
    -- print("data_race_map:\n")
    -- print(data_race_map)
    for key, value in pairs(data_race_map) do
        table.insert(output_table, string.format(key .. ":[Race] Possible data race during %s of size %s at %s by thread %s (%s)",
            summarize_rw(value.rw),
            summarize_table_keys(value.size, false, true),
            summarize_table_keys(value.addr, true),
            summarize_table_keys(value.thr),
            summarize_links(value.link)))
    end
    for key, value in pairs(general_map) do
        table.insert(output_table, string.format(key .. " (%s)", summarize_links(value.link)))
    end
    table.sort(output_table)
    local num_output_lines = 0
    for _, output_line in pairs(output_table) do
        error_file_handle:write(output_line .. "\n")
        num_output_lines = num_output_lines + 1
    end
    vim.notify("Processed " .. num_errors .. " errors from '" .. xml_file .. "' into " .. num_output_lines .. " locations.")
    error_file_handle:close()
end

M.run_valgrind = function(args)
    local xml_file = vim.fn.tempname()

    local valgrind_cmd_line = "!valgrind --num-callers=500 --xml=yes --xml-file=" .. xml_file .. " " .. args.args

    vim.cmd(valgrind_cmd_line)
    M.valgrind_load_xml({args = xml_file})

    -- print("Valgrind xml output written to: " .. xml_file)
    vim.fn.delete(xml_file)
end

M.valgrind_load_xml = function(args)
    local xml_file = args.args
    local error_file = vim.fn.tempname()

    M.extract_valgrind_error(xml_file, error_file)
    local efm = vim.bo.efm
    vim.bo.efm = "%f:%l:%m"
    vim.cmd("cfile " .. error_file)
    vim.bo.efm = efm

    -- print("Valgrind error log written to: " .. error_file)
    vim.fn.delete(error_file)
end

M.sanitizer_load_log = function(args)
    local log_file = args.args
    local error_file = vim.fn.tempname()

    local log_file_handle = io.open(log_file, "r")
    if not log_file_handle then
        print("Failed to read sanitizer log file: " .. log_file)
        return
    end
    local error_file_handle = io.open(error_file, "w")
    if not error_file_handle then
        print("Failed to open error file: " .. error_file)
        return
    end

    local message = "NO MESSAGE"
    local last_addr = "NO ADDRESS"
    local general_map = {}
    local rw_op_map = {}
    local mutex_created_map = {}
    local heap_allocation_map = {}
    local leak_map = {}
    local target
    local prev_target
    local num_processed_lines = 0
    for line in log_file_handle:lines() do
        if starts_with(line, "allocated by") then
            message = last_addr .. " " .. line
            prev_target = nil
        elseif not starts_with(line, "    #") then
            message = line
            prev_target = nil
            local addr = string.match(line, "(0x%x+)")
            if addr then
                last_addr = addr
            end
        else
            target = string.match(line, "#%d+ 0x%x+ .* (.+)")  -- ASAN format
            if not target then
                target = string.match(line, "#%d+ .* (.+) %(.+%)")  -- TSAN format
            end
            if not target then
                print("Failed to parse link target from line:\n" .. line)
                goto not_source_file_continue
                -- return
            end
            if not starts_with(target, "/home/") then -- TODO: Use git_root instead!
                goto not_source_file_continue
            end
            local filename, line_number = string.match(target, "(%S+):(%d+)")
            if not filename or not line_number then
                goto not_source_file_continue
            end
            -- Add leading zeroes to line numbers for sorting.
            target = filename .. ":" .. string.format("%06d", line_number)

            local key, rw_op, size, addr, thr, mutex, leak_type, num_objs
            rw_op, size, addr, thr = string.match(message, "^%s*(.*) of size (%d+) at (0x%x+) by (.*):$")
            if rw_op then
                -- TODO: This should probably be controlled by a "compactify" option.
                -- "Read/Write/Previous read/Previous write" operations.
                key = target
                if not rw_op_map[key] then
                    rw_op_map[key] = { rw_op = {}, size = {}, addr = {}, thr = {}, misc = {}, link = {} }
                end
                rw_op_map[key].rw_op[rw_op] = true
                rw_op_map[key].size[size] = true
                rw_op_map[key].addr[addr] = true
                rw_op_map[key].thr[thr] = true
                populate_link(rw_op_map[key].link, prev_target)
                goto finished_with_line_continue
            end

            mutex = string.match(message, "^%s*Mutex (.*) created at:$")
            if mutex then
                -- Mutex creation.
                key = target
                if not mutex_created_map[key] then
                    mutex_created_map[key] = { mutex = {}, link = {} }
                end
                mutex_created_map[key].mutex[mutex] = true
                populate_link(mutex_created_map[key].link, prev_target)
                goto finished_with_line_continue
            end

            size, addr, thr = string.match(message, "^%s*Location is heap block of size (%d+) at (0x%x+) allocated by (.*):$")
            if size then
                -- Heap block allocation.
                key = target
                if not heap_allocation_map[key] then
                    heap_allocation_map[key] = { size = {}, addr = {}, thr = {}, link = {} }
                end
                heap_allocation_map[key].size[size] = true
                heap_allocation_map[key].addr[addr] = true
                heap_allocation_map[key].thr[thr] = true
                populate_link(heap_allocation_map[key].link, prev_target)
                goto finished_with_line_continue
            end

            leak_type, size, num_objs = string.match(message, "^%s*(.*) leak of (%d+) byte%(s%) in (%d+) object%(s%) allocated from:$")
            if leak_type then
                -- Memory leak.
                key = target
                if not leak_map[key] then
                    leak_map[key] = { leak_type = {}, size = {}, num_objs = {}, link = {} }
                end
                leak_map[key].leak_type[leak_type] = true
                leak_map[key].size[size] = true
                leak_map[key].num_objs[num_objs] = true
                populate_link(leak_map[key].link, prev_target)
                goto finished_with_line_continue
            end

            -- Other general messages.
            key = target .. ":" .. message
            if not general_map[key] then
                general_map[key] = { link = {} }
            end
            populate_link(general_map[key].link, prev_target)

            ::finished_with_line_continue::
            num_processed_lines = num_processed_lines + 1
            prev_target = string.match(target, ".*/(.+)")
        end
        ::not_source_file_continue::
    end
    log_file_handle:close()

    local output_table = {}
    -- print("rw_op_map:\n")
    -- print(rw_op_map)
    for key, value in pairs(rw_op_map) do
        table.insert(output_table, string.format(key ..
            ":%s of size %s at %s by thread %s: (%s)",
            summarize_table_keys(value.rw_op),
            summarize_table_keys(value.size, false, true),
            summarize_table_keys(value.addr, true),
            summarize_table_keys(value.thr),
            summarize_links(value.link)))
    end
    -- print("mutex_created_map:\n")
    -- print(mutex_created_map)
    for key, value in pairs(mutex_created_map) do
        table.insert(output_table, string.format(key ..
            ":Mutex %s created: (%s)",
            summarize_table_keys(value.mutex),
            summarize_links(value.link)))
    end
    -- print("heap_allocation_map:\n")
    -- print(heap_allocation_map)
    for key, value in pairs(heap_allocation_map) do
        table.insert(output_table, string.format(key ..
            ":Location is heap block of size %s at %s allocated by %s: (%s)",
            summarize_table_keys(value.size, false, true),
            summarize_table_keys(value.addr, true),
            summarize_table_keys(value.thr),
            summarize_links(value.link)))
    end
    -- print("leak_map:\n")
    -- print(leak_map)
    for key, value in pairs(leak_map) do
        table.insert(output_table, string.format(key ..
            ":%s leak of %s byte(s) in %s object(s) allocated from: (%s)",
            summarize_table_keys(value.leak_type),
            summarize_table_keys(value.size, false, true),
            summarize_table_keys(value.num_objs, false, true),
            summarize_links(value.link)))
    end
    -- print("general_map:\n")
    -- print(general_map)
    for key, value in pairs(general_map) do
        table.insert(output_table, string.format(key .. " (%s)", summarize_links(value.link)))
    end
    table.sort(output_table)
    local num_output_lines = 0
    for _, output_line in pairs(output_table) do
        error_file_handle:write(output_line .. "\n")
        num_output_lines = num_output_lines + 1
    end
    error_file_handle:close()

    local efm = vim.bo.efm
    vim.bo.efm = "%f:%l:%m"
    vim.cmd("cfile " .. error_file)
    vim.bo.efm = efm

    -- Inform user of some stats.
    vim.notify("Processed " .. num_processed_lines .. " lines from '" .. log_file .. "' into " .. num_output_lines .. " locations.")

    -- print("Sanitizer error log written to: " .. error_file)
    vim.fn.delete(error_file)
end

return M
