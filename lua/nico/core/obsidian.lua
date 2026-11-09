local M = {}

local uv = vim.uv or vim.loop
local is_windows = vim.fn.has("win32") == 1

-- strftime flag for "no zero padding": "%-d" on Linux/macOS, "%#d" on Windows
local NP = is_windows and "#" or "-"

local function expand(path)
    return vim.fn.expand(path)
end

local function is_dir(path)
    return vim.fn.isdirectory(path) == 1
end

local function normalize_workspace(workspace)
    if type(workspace) ~= "table" or type(workspace.path) ~= "string" then
        return nil
    end

    local normalized = vim.deepcopy(workspace)
    normalized.path = vim.fs.normalize(expand(normalized.path))

    if not is_dir(normalized.path) then
        return nil
    end

    if type(normalized.name) ~= "string" or normalized.name == "" then
        normalized.name = vim.fs.basename(normalized.path)
    end

    return normalized
end

local function detect_vault_root()
    local candidates = {
        vim.api.nvim_buf_get_name(0),
        uv.cwd(),
    }

    for _, candidate in ipairs(candidates) do
        if type(candidate) == "string" and candidate ~= "" then
            local start = candidate

            if vim.fn.filereadable(start) == 1 then
                start = vim.fs.dirname(start)
            end

            local root = vim.fs.find(".obsidian", {
                path = start,
                upward = true,
                type = "directory",
                limit = 1,
            })[1]

            if root then
                return vim.fs.dirname(root)
            end
        end
    end

    return nil
end

local function slugify(text)
    local slug = text:lower()
    slug = slug:gsub("[^a-z0-9%s-]", "")
    slug = slug:gsub("%s+", "-")
    slug = slug:gsub("%-+", "-")
    slug = slug:gsub("^%-", "")
    slug = slug:gsub("%-$", "")

    return slug
end

local function is_date_title(text)
    return type(text) == "string" and text:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil
end

local function open_with_system(path)
    if vim.ui.open then
        vim.ui.open(path)
        return
    end

    if is_windows then
        vim.fn.jobstart({ "cmd.exe", "/c", "start", "", path }, {
            detach = true,
        })
    else
        vim.fn.jobstart({ "xdg-open", path }, {
            detach = true,
        })
    end
end

local function find_daily_template(workspaces)
    for _, workspace in ipairs(workspaces) do
        if type(workspace.path) == "string" then
            local template = vim.fs.joinpath(workspace.path, "templates", "daily.md")

            if vim.fn.filereadable(template) == 1 then
                return "daily.md"
            end
        end
    end

    return nil
end

local LOWER_AMPM = "__OBSIDIAN_LOWER_AMPM__"

-- Translate Obsidian/moment.js tokens to strftime.
local function translate_obsidian_datetime_format(format)
    local tokens = {
        { "YYYY", "%Y" },
        { "YY", "%y" },
        { "MMMM", "%B" },
        { "MMM", "%b" },
        { "MM", "%m" },
        { "M", "%" .. NP .. "m" },
        { "dddd", "%A" },
        { "ddd", "%a" },
        { "DD", "%d" },
        { "D", "%" .. NP .. "d" },
        { "HH", "%H" },
        { "H", "%" .. NP .. "H" },
        { "hh", "%I" },
        { "h", "%" .. NP .. "I" },
        { "mm", "%M" },
        { "ss", "%S" },
        { "A", "%p" },
        { "a", LOWER_AMPM },
    }

    local chunks = {}
    local i = 1

    while i <= #format do
        local char = format:sub(i, i)

        if char == "[" then
            -- [literal text] is escaped in moment.js
            local close_idx = format:find("]", i + 1, true)

            if close_idx then
                chunks[#chunks + 1] = (format:sub(i + 1, close_idx - 1):gsub("%%", "%%%%"))
                i = close_idx + 1
            else
                chunks[#chunks + 1] = char
                i = i + 1
            end
        else
            local matched = false

            for _, token in ipairs(tokens) do
                local source, target = token[1], token[2]

                if format:sub(i, i + #source - 1) == source then
                    chunks[#chunks + 1] = target
                    i = i + #source
                    matched = true
                    break
                end
            end

            if not matched then
                chunks[#chunks + 1] = (char == "%") and "%%" or char
                i = i + 1
            end
        end
    end

    return table.concat(chunks)
end

local function render_obsidian_datetime(format)
    local strftime_format = translate_obsidian_datetime_format(format)
    local ok, rendered = pcall(os.date, strftime_format)

    if not ok then
        return "{{invalid date format}}"
    end

    rendered = rendered:gsub(LOWER_AMPM, function()
        return os.date("%p"):lower()
    end)

    return rendered
end

-- Adds support for {{date:FORMAT}} and {{time:FORMAT}} in templates.
function M.patch_template_substitutions()
    if vim.g.obsidian_template_patch_applied then
        return
    end

    local ok, templates = pcall(require, "obsidian.templates")

    if not ok or type(templates.substitute_template_variables) ~= "function" then
        return
    end

    local original = templates.substitute_template_variables

    -- Varargs: the signature differs between obsidian.nvim versions/forks.
    templates.substitute_template_variables = function(text, ...)
        text = text:gsub("{{date:([^}]+)}}", function(format)
            return (render_obsidian_datetime(format))
        end)

        text = text:gsub("{{time:([^}]+)}}", function(format)
            return (render_obsidian_datetime(format))
        end)

        return original(text, ...)
    end

    vim.g.obsidian_template_patch_applied = true
end

function M.setup_markdown_buffer(bufnr)
    local opt = vim.opt_local

    opt.wrap = true
    opt.linebreak = true
    opt.conceallevel = 0
    opt.concealcursor = "nc"
    opt.spell = false
    opt.textwidth = 100

    vim.api.nvim_buf_call(bufnr, function()
        vim.opt_local.formatoptions:append({ "n", "2" })
        vim.opt_local.formatoptions:remove("t")
    end)
end

function M.workspaces()
    local workspaces = {}
    local seen = {}

    local function add_workspace(workspace)
        local normalized = normalize_workspace(workspace)

        if normalized and not seen[normalized.path] then
            seen[normalized.path] = true
            table.insert(workspaces, normalized)
        end
    end

    -- Custom workspaces
    if type(vim.g.obsidian_workspaces) == "table" then
        for _, workspace in ipairs(vim.g.obsidian_workspaces) do
            add_workspace(workspace)
        end
    end

    local documents = vim.fs.joinpath(vim.env.USERPROFILE or expand("~"), "Documents")

    add_workspace({
        name = "personal",
        path = vim.fs.joinpath(documents, "Obsidian", "Personal"),
    })

    add_workspace({
        name = "work",
        path = vim.fs.joinpath(documents, "Obsidian", "Work"),
    })

    local detected_root = detect_vault_root()

    if detected_root then
        add_workspace({
            name = vim.fs.basename(detected_root),
            path = detected_root,
        })
    end

    -- Fallback if no vault exists
    if #workspaces == 0 then
        local fallback = vim.fs.joinpath(documents, "Obsidian", "Personal")

        vim.fn.mkdir(fallback, "p")
        vim.fn.mkdir(vim.fs.joinpath(fallback, ".obsidian"), "p")

        add_workspace({
            name = "personal",
            path = fallback,
        })
    end

    return workspaces
end

function M.opts()
    -- Make sure {{date:...}} works before obsidian.nvim renders any template.
    M.patch_template_substitutions()

    local workspaces = M.workspaces()
    local template = find_daily_template(workspaces)

    if not template then
        vim.schedule(function()
            vim.notify(
                "obsidian: <vault>/templates/daily.md not found, using default daily note format",
                vim.log.levels.WARN
            )
        end)
    end

    return {
        workspaces = workspaces,

        notes_subdir = "notes",
        new_notes_location = "notes_subdir",
        preferred_link_style = "wiki",
        sort_by = "modified",
        sort_reversed = true,
        open_notes_in = "current",

        completion = {
            nvim_cmp = true,
            min_chars = 2,
        },

        daily_notes = {
            folder = "notes/dailies",
            date_format = "%Y-%m-%d",
            alias_format = "%A, %B %" .. NP .. "d, %Y",
            default_tags = { "daily", "journal" },
            template = template,
        },

        templates = {
            folder = "templates",
            date_format = "%Y-%m-%d",
            time_format = "%H:%M",
            substitutions = {
                weekday = function()
                    return os.date("%A")
                end,
                cursor = function()
                    return "<++>"
                end,
            },
        },

        note_id_func = function(title)
            local suffix = title and slugify(title) or ""

            -- Use the note title as the ID; fall back to today's date.
            -- Daily notes titled YYYY-MM-DD therefore get IDs like 2026-11-08.
            if suffix == "" then
                return os.date("%Y-%m-%d")
            end

            return suffix
        end,

        note_frontmatter_func = function(note)
            -- Skip the title alias for daily notes (title == date == id),
            -- otherwise the alias list gets a redundant "2026-05-18" entry.
            if note.title and not is_date_title(note.title) then
                note:add_alias(note.title)
            end

            local out = {
                id = note.id,
                aliases = note.aliases,
                tags = note.tags,
            }

            if note.metadata ~= nil and not vim.tbl_isempty(note.metadata) then
                for key, value in pairs(note.metadata) do
                    out[key] = value
                end
            end

            return out
        end,

        mappings = {
            ["gf"] = {
                action = function()
                    return require("obsidian").util.gf_passthrough()
                end,
                opts = {
                    noremap = false,
                    expr = true,
                    buffer = true,
                },
            },

            ["<CR>"] = {
                action = function()
                    return require("obsidian").util.smart_action()
                end,
                opts = {
                    buffer = true,
                    expr = true,
                },
            },

            ["<leader>oc"] = {
                action = function()
                    return require("obsidian").util.toggle_checkbox()
                end,
                opts = {
                    buffer = true,
                    desc = "Toggle checkbox",
                },
            },
        },

        picker = {
            name = "telescope.nvim",
            note_mappings = {
                new = "<C-x>",
                insert_link = "<C-l>",
            },
            tag_mappings = {
                tag_note = "<C-x>",
                insert_tag = "<C-l>",
            },
        },

        attachments = {
            img_folder = "assets/imgs",
            img_name_func = function()
                return string.format("%s-", os.date("%Y%m%d-%H%M%S"))
            end,
        },

        follow_url_func = open_with_system,
        follow_img_func = open_with_system,

        ui = {
            enable = false,
        },

        callbacks = {
            enter_note = function()
                M.setup_markdown_buffer(0)
            end,
        },
    }
end

return M