local M = {}

function M.setup(opts)
    opts = opts or {}

    vim.api.nvim_create_user_command("Valgrind", M.run_valgrind, { nargs = 1 })
    vim.api.nvim_create_user_command("ValgrindLoadXml", M.load_xml, { nargs = 1 })
end

local function starts_with(str, start)
    return str:sub(1, #start) == start
end

-- TODO: Investigate why this doesn't work on calls subsequent to the first call.
M.extract_error = function(filexml, fileerr)
    -- TODO: Use luarocks for this. See: https://github.com/theHamsta/nvim_rocks
    local xml2lua = require("valgrind.lib.xml2lua.xml2lua")
    local handler = require("valgrind.lib.xml2lua.xmlhandler.tree")

    -- TODO: Check that the following supports valgrind tools other than memcheck and helgrind.
    local parser = xml2lua.parser(handler)
    parser:parse(xml2lua.loadFile(filexml))

    -- TODO: Clean up the code.
    local h = io.open(fileerr, "w")
    local error = handler.root.valgrindoutput
    if error.error and #error.error > 1 then
        error = error.error
    end
    for _, e in pairs(error) do
        if not e.kind then goto not_error_continue end
        if not e.stack then goto not_error_continue end
        local output = ""
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
                output = output .. f.dir .. "/"
                target = f.file .. ":"
                if f.line then
                    target = target .. f.line
                else
                    target = target .. "1"
                end
                output = output .. target .. ":"
                if e.kind then
                    output = output .. "[" .. e.kind .. "] "
                end
                if e.what then
                    output = output .. e.what
                elseif e.xwhat then
                    output = output .. e.xwhat.text
                end
                if prev_target then
                    output = output .. " (->" .. prev_target .. ")"
                else
                    output = output .. " (END)" -- reached bottom of call stack
                end
                output = output .. "\n"
                prev_target = target
                ::not_file_continue::
            end
            ::not_frame_continue::
        end
        if h then h:write(output) end
        ::not_error_continue::
    end
    if h then h:close() end

end

M.run_valgrind = function(args)
    local xml_file = vim.fn.tempname()

    local valgrind_cmd_line = "!valgrind --num-callers=500 --xml=yes --xml-file=" .. xml_file .. " " .. args.args

    vim.cmd(valgrind_cmd_line)
    M.load_xml({args = xml_file})

    vim.fn.delete(xml_file)
end

M.load_xml = function(args)
    local xml_file = args.args
    local error_file = vim.fn.tempname()

    M.extract_error(xml_file, error_file)
    local efm = vim.bo.efm
    vim.bo.efm = "%f:%l:%m"
    vim.cmd("cfile " .. error_file)
    vim.bo.efm = efm

    vim.fn.delete(error_file)
end

return M
