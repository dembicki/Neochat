local M = {}
-- Module-level variables
M.side = "L" -- wincmd sides: H, J, K, or L
M.bufname = "neocursor"

local Job = require "plenary.job"
local async = require("plenary.async")
local await = async.await
local async_void = async.void
local util = require "neocursor.util"
local GetVisualSelection = require("neocursor.util").GetVisualSelection
local GetVisualSelectionLineNos = require("neocursor.util").GetVisualSelectionLineNos
local vimecho = require("neocursor.util").vimecho

function M.gen_aichat_wrapper_script(input_file, output_file)
    return util.dedent(
        string.format(
            [==[
                #!/bin/bash
                aichat < "%s"
                cols="$(tput cols)"
                msg="Keep Y/N? "
                y_color=$(tput setaf 2)
                n_color=$(tput setaf 1)
                reset_color=$(tput sgr0)
                msg_colorized="Keep ${y_color}Y${reset_color}/${n_color}N${reset_color}? "
                padding=$((($cols - ${#msg}) / 2))
                printf "%%${padding}s" ""
                echo
                echo -n -e "$msg_colorized"
                while true; do
                    read -r -n 1 key
                    if test "$key" == "Y" || test "$key" == "y"; then
                        exit 0
                    elif test "$key" == "N" || test "$key" == "n"; then
                        exit 1
                    fi
                done
                ]==],
            input_file --, output_file
        )
    )
end

function M.get_openai_api_key()
    return vim.fn.getenv("OPENAI_KEY")
end

function M.create_tmp_aichat_dir()
    local tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
    local openai_key = M.get_openai_api_key()
    local config_yml =
        string.format(
        util.dedent(
            [==[
            api_key: %s

            model: gpt-4
            save: true
            highlight: true 
            temperature: 0
            light_theme: true
            conversation_first: true

            ]==]
        ),
        openai_key
    )
    local cfg_file = io.open(util.join_path(tmp_dir, "config.yaml"), "w")
    cfg_file:write(config_yml)
    cfg_file:close()
    return tmp_dir
end

function M.Aichat(input)
    local start_line, end_line = GetVisualSelectionLineNos()
    local bufnr = vim.api.nvim_get_current_buf()

    vim.cmd("wincmd n")
    vim.cmd(string.format("wincmd %s", M.side))

    local aichat_cfg_dir = M.create_tmp_aichat_dir()
    vim.fn.setenv("AICHAT_CONFIG_DIR", aichat_cfg_dir)
    local input_file = "/tmp/aichat_input"
    -- aichat writes it's msg history into messages.md, so we can read
    -- the chat output from here later
    local output_file = util.join_path(aichat_cfg_dir, "messages.md")
    local script_file = "/tmp/aichat_script.sh"
    local file = nil
    local script = nil

    if input then
        script = M.gen_aichat_wrapper_script(input_file, output_file)
        file = io.open(input_file, "w")
        -- TODO: generate an alternate wrapper script that doesn't pass in user input
        file:write(input)
        file:close()
        local file = nil
        if input_file ~= nil then
            file = io.open(input_file, "w")
            file:write(input)
            file:close()
        end
    else
        script = [[
#!/bin/bash
exec aichat]]
    end

    file = io.open(script_file, "w")
    file:write(script)
    file:close()

    local term_id =
        vim.fn.termopen(
        "bash " .. script_file,
        {
            on_exit = function(job_id, exit_code, event)
                if exit_code == 0 then
                    local output = M.extract_last_backtick_value(M.get_last_aichat_response(output_file))
                    M.replace_lines(start_line, end_line, output, bufnr)
                else
                    -- print("NNN!!!")
                    vimecho("N :(")
                end
                os.remove(input_file) -- clean up temporary files
                os.remove(script_file)
            end,
            stdout_buffered = true,
            stderr_buffered = true
        }
    )
end

function M.replace_lines(start_line, end_line, new_lines, bufnr)
    bufnr = bufnr or 0 -- use the current buffer if none is specified
    vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, vim.split(new_lines, "\n"))
end

function M.aichat_wrapper(args)
    local selection = GetVisualSelection()
    if args == nil or args == "" then
        -- No args and not in visual mode, so just open up a chat win
        M.Aichat()
    else
        if string.len(selection) then
            -- if vim.fn.mode() == "v" or vim.fn.mode() == "V" or vim.fn.mode() == "^V" then
            -- Visual mode and args, so marshall the visually selected
            -- text into the prompt
            local prompt =
                table.concat(
                {
                    "You are a coding expert. I will provide you with code and instructions, reply with the updated code and nothing else. Do no provide any explanation or commentary. Make sure to use a markdown block with language indicated (eg ```python)\n\n Code: \n\n```\n",
                    GetVisualSelection(),
                    "\n```\n\nInstruction: \n\n```\n",
                    args,
                    "\n```\n"
                }
            )

            M.Aichat(prompt)
        else
            -- Args provided, but no visual mode, so just start aichat
            -- with the provided prompt
            M.Aichat(args)
        end
    end
end

function M.get_buf_text(bufnr)
    -- bufnr is the buffer number. If nil, the current buffer is used.
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    -- Get the number of lines in the buffer
    local line_count = vim.api.nvim_buf_line_count(bufnr)

    -- Get all lines from the buffer
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, line_count, false)

    -- Join all lines into a single string
    local text = table.concat(lines, "\n")

    return text
end

function M.extract_last_backtick_value(content)
    local last_block = nil
    local pattern = "```.-\n(.-)```"

    for block in string.gmatch(content, pattern) do
        last_block = block
    end

    local function trim(s)
        return s:match "^%s*(.-)%s*$"
    end

    local output
    if last_block then
        output = last_block
    else
        output = content
    end
    return trim(output)
end

function M.read_file(file_path)
    local file = io.open(file_path, "r")
    if not file then
        return nil
    end

    local content = file:read("*all")
    file:close()

    return content
end

function M.extract_markdown_content(file_path)
    local content = M.read_file(file_path)
    if not content then
        return nil
    end

    return M.extract_last_backtick_value(content)
end

function M.get_last_aichat_response(file_path)
    local file = io.open(file_path, "r")
    local lines = {}
    local block = {}
    local block_delim = "--------"

    for line in file:lines() do
        table.insert(lines, line)
    end

    file:close()

    local started_block = false
    local ended_block = false
    -- iterate through the messages.md file in reverse and extract the contents
    -- of the last block
    for i = #lines, 1, -1 do
        local line = lines[i]
        if started_block and not ended_block then
            table.insert(block, line)
        end
        if line == block_delim then
            if not started_block then
                started_block = true
            else
                ended_block = true
                table.remove(block)
                break
            end
        end
    end

    local text = table.concat(util.reverse_array(block), "\n")
    return text
end

vim.cmd([[
  command! -nargs=* -range Aichat lua require'neocursor'.aichat_wrapper(<q-args>)
]])

return M
