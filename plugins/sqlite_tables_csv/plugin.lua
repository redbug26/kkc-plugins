local kkc = require("kkc")

local function lower_ext(path)
    local ext = path:match("%.([^%.\\/]+)$")
    return ext and ext:lower() or ""
end

local function can_handle(path)
    local ext = lower_ext(path)
    return ext == "sqlite" or ext == "sqlite3" or ext == "db"
end

local function safe_exec(program, args, cwd)
    local ok, result = pcall(kkc.exec, program, args, cwd)
    if not ok or not result then
        return { success = false, status = -1, stdout = "", stderr = tostring(result) }
    end
    return result
end

local function trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function quote_ident(name)
    -- SQLite identifier quoting with doubled double-quotes.
    return '"' .. (name or ""):gsub('"', '""') .. '"'
end

local function sanitize_filename(name)
    local value = trim((name or ""):gsub("[%c%z]", " "))
    value = value:gsub("[\\/:*?\"<>|]", "_")
    value = value:gsub("%s+", " ")
    value = trim(value)
    if value == "" then
        value = "table"
    end
    return value
end

local function unique_csv_name(used, table_name)
    local base = sanitize_filename(table_name)
    local idx = 0
    while true do
        local name
        if idx == 0 then
            name = base .. ".csv"
        else
            name = string.format("%s (%d).csv", base, idx)
        end
        if not used[name] then
            used[name] = true
            return name
        end
        idx = idx + 1
    end
end

local function list_tables(path)
    local query = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"
    local result = safe_exec("sqlite3", { path, query }, nil)
    if not result.success then
        return nil, (result.stderr ~= "" and result.stderr) or "sqlite3 failed to list tables"
    end

    local tables = {}
    for line in (result.stdout or ""):gmatch("[^\r\n]+") do
        local table_name = trim(line)
        if table_name ~= "" then
            tables[#tables + 1] = table_name
        end
    end
    return tables, nil
end

local function export_table_csv(path, table_name)
    local query = "SELECT * FROM " .. quote_ident(table_name) .. ";"
    return safe_exec("sqlite3", { "-header", "-csv", path, query }, nil)
end

local function write_readme(destination, source_path, exported_count, tables_count, errors)
    local lines = {
        "SQLite table export",
        "",
        "Source: " .. source_path,
        "Tables found: " .. tostring(tables_count),
        "CSV exported: " .. tostring(exported_count),
        "",
        "Each CSV contains one table with headers.",
    }

    if errors and #errors > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Errors:"
        for _, e in ipairs(errors) do
            lines[#lines + 1] = "- " .. e
        end
    end

    kkc.write_file(kkc.path_join(destination, "README.txt"), table.concat(lines, "\n") .. "\n")
end

local function extract_sqlite(path, destination)
    local tables, err = list_tables(path)
    if not tables then
        error("sqlite_tables_csv: " .. tostring(err), 0)
    end

    local used = {}
    local exported = 0
    local errors = {}

    for _, table_name in ipairs(tables) do
        local csv = export_table_csv(path, table_name)
        if csv.success then
            local filename = unique_csv_name(used, table_name)
            kkc.write_file(kkc.path_join(destination, filename), csv.stdout or "")
            exported = exported + 1
        else
            local msg = (csv.stderr ~= "" and csv.stderr) or "sqlite3 export failed"
            errors[#errors + 1] = string.format("%s: %s", table_name, trim(msg))
        end
    end

    write_readme(destination, path, exported, #tables, errors)

    if exported == 0 and #tables > 0 then
        error("sqlite_tables_csv: no table could be exported", 0)
    end

    return true
end

kkc.register_archive_plugin({
    name = "sqlite_tables_csv",
    version = "1.0.0",
    description = "Open SQLite DB as CSV files (one table = one CSV)",
    mime_types = { "application/x-sqlite3" },
    extensions = { ".sqlite", ".sqlite3", ".db" },
    can_handle = can_handle,
    extract = extract_sqlite,
})
