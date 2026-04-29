local kkc = require("kkc")
local dsk = require("dsk")

local function trim_right(value)
    return (value:gsub("%s+$", ""))
end

local function sanitize_export_component(value)
    -- Keep only conservative portable filename chars.
    value = value:gsub("[^%w._%-]", "_")
    value = value:gsub("_+", "_")
    value = value:gsub("^_+", "")
    value = value:gsub("_+$", "")
    return value
end

local function amsdos_name(raw_name)
    local base = trim_right(raw_name:sub(1, 8):gsub("[%z\1-\31\127]", ""))
    local ext = trim_right(raw_name:sub(9, 11):gsub("[%z\1-\31\127]", ""))
    base = sanitize_export_component(base)
    ext = sanitize_export_component(ext)
    if base == "" then
        base = "NONAME"
    end
    if ext == "" then
        return base
    end
    return base .. "." .. ext
end

local function sector_data(track, side, id)
    return dsk.getsector(track, side, id) or ""
end

local function read_block(block_num)
    local sector_num = block_num * 2
    local track_num = math.floor(sector_num / 9)
    local sector_id = 0xc1 + (sector_num % 9)
    local first = sector_data(track_num, 0, sector_id)

    sector_num = sector_num + 1
    track_num = math.floor(sector_num / 9)
    sector_id = 0xc1 + (sector_num % 9)
    local second = sector_data(track_num, 0, sector_id)

    return first .. second
end

local function upper_ascii(byte)
    if byte >= 0x61 and byte <= 0x7a then
        return byte - 0x20
    end
    return byte
end

-- Compare AMSDOS 8.3 name bytes from header and catalog entry while ignoring
-- CPC attribute bits (bit 7 may be set in extension bytes).
local function amsdos_name_matches(raw_name, data)
    if #raw_name < 11 or #data < 12 then
        return false
    end
    for i = 1, 11 do
        local header_b = (data:byte(1 + i) or 0) & 0x7f
        local entry_b = (raw_name:byte(i) or 0) & 0x7f
        if upper_ascii(header_b) ~= upper_ascii(entry_b) then
            return false
        end
    end
    return true
end

local function is_plausible_amsdos_name_byte(byte)
    -- Allow uppercase letters, digits, space, underscore, hyphen and dot.
    return (byte >= 0x41 and byte <= 0x5a)
        or (byte >= 0x30 and byte <= 0x39)
        or byte == 0x20
        or byte == 0x5f
        or byte == 0x2d
        or byte == 0x2e
end

local function amsdos_checksum_ok(data)
    if #data < 128 then
        return false
    end
    local sum = 0
    for i = 1, 67 do
        sum = (sum + (data:byte(i) or 0)) & 0xffff
    end
    local stored = (data:byte(68) or 0) + (data:byte(69) or 0) * 256
    return sum == stored
end

local function looks_like_amsdos_header(data)
    if #data < 128 then
        return false
    end

    -- User number is usually in CPC range 0..15 (sometimes up to 31).
    local user = data:byte(1) or 0xff
    if user > 31 then
        return false
    end

    -- Filename field should look like a CPC 8.3 name.
    local has_non_space = false
    for i = 2, 12 do
        local b = (data:byte(i) or 0) & 0x7f
        if not is_plausible_amsdos_name_byte(b) then
            return false
        end
        if b ~= 0x20 then
            has_non_space = true
        end
    end
    if not has_non_space then
        return false
    end

    local lo = data:byte(25) or 0
    local hi = data:byte(26) or 0
    local length = lo + hi * 256
    if length <= 0 or length > (#data - 128) then
        return false
    end

    local file_type = data:byte(19) or 0xff
    local content_kind = (file_type >> 1) & 0x07
    if content_kind > 4 then
        return false
    end

    -- Bytes 12..15 are expected to be zero in classic AMSDOS header.
    for i = 13, 16 do
        if (data:byte(i) or 0) ~= 0 then
            return false
        end
    end

    return true
end

local function detect_amsdos_header(raw_name, data)
    if #data < 128 then
        return false
    end

    if amsdos_checksum_ok(data) and looks_like_amsdos_header(data) then
        return true
    end

    -- Preferred: catalog name and header name match (ignoring attribute bit 7).
    if amsdos_name_matches(raw_name, data) and looks_like_amsdos_header(data) then
        return true
    end

    -- Fallback for renamed files or malformed checksum/name fields found in the wild.
    return looks_like_amsdos_header(data)
end

local function amsdos_header_status(raw_name, data)
    if not detect_amsdos_header(raw_name, data) then
        return ""
    end
    if amsdos_checksum_ok(data) then
        return "OK"
    end
    return "TOL"
end

local function strip_amsdos_header(raw_name, data)
    if not detect_amsdos_header(raw_name, data) then
        return data
    end
    local lo = data:byte(25) or 0
    local hi = data:byte(26) or 0
    local length = lo + hi * 256
    if length > 0 and length <= (#data - 128) then
        return data:sub(129, 128 + length)
    end

    return data
end

local function amsdos_load_exec(data)
    if #data < 128 then
        return nil
    end
    -- Same offsets as CrocoDS: load at 0x15/0x16, exec at 0x1A/0x1B (0-based).
    -- Lua string.byte is 1-based, so add +1 to each offset.
    local load = (data:byte(0x17) or 0) * 256 + (data:byte(0x16) or 0)
    local exec = (data:byte(0x1C) or 0) * 256 + (data:byte(0x1B) or 0)
    return string.format("L=%04X E=%04X", load, exec)
end

local function read_catalog_file_raw(entries)
    table.sort(entries, function(left, right)
        return (left.numextension or 0) < (right.numextension or 0)
    end)

    local data = ""
    for _, entry in ipairs(entries) do
        local part = ""
        for _, block in ipairs(entry.blocks or {}) do
            part = part .. read_block(block)
        end

        local records = entry.nbrecords or 0
        if records > 0 and records < 128 then
            part = part:sub(1, records * 128)
        end
        data = data .. part
    end

    return data
end

local function read_catalog_file(entries)
    local raw_data = read_catalog_file_raw(entries)
    return strip_amsdos_header(entries[1].filename, raw_data)
end

local function basename(path)
    return path:match("([^/\\]+)$") or path
end

local function file_size(path)
    local file = io.open(path, "rb")
    if not file then
        return 0
    end
    local size = file:seek("end") or 0
    file:close()
    return size
end

local function validate_dsk_header(path)
    local file = io.open(path, "rb")
    if not file then
        return nil, "unable to open DSK"
    end

    local header = file:read(34) or ""
    local is_standard = header:sub(1, 8) == "MV - CPC"
    local is_extended = header:sub(1, 16) == "EXTENDED CPC DSK"
    if not is_standard and not is_extended then
        file:close()
        return nil, "not an Amstrad CPC DSK image"
    end

    file:seek("set", 48)
    local tracks = (file:read(1) or "\0"):byte(1) or 0
    local sides = (file:read(1) or "\0"):byte(1) or 0
    local lo = (file:read(1) or "\0"):byte(1) or 0
    local hi = (file:read(1) or "\0"):byte(1) or 0
    local track_size = lo + hi * 256
    local sizes = file:read(204) or ""
    file:close()

    if tracks < 1 or tracks > 84 then
        return nil, "invalid DSK track count"
    end
    if sides < 1 or sides > 2 then
        return nil, "invalid DSK side count"
    end

    local total_track_size = 0
    if is_extended then
        for idx = 1, math.min(#sizes, tracks * sides) do
            total_track_size = total_track_size + (sizes:byte(idx) or 0) * 256
        end
        if total_track_size == 0 then
            return nil, "invalid extended DSK track table"
        end
    else
        if track_size < 256 or track_size > 65535 then
            return nil, "invalid DSK track size"
        end
        total_track_size = tracks * sides * track_size
    end

    local expected_max = 256 + total_track_size
    local size = file_size(path)
    if size > 0 and expected_max > size + 65536 then
        return nil, "DSK header announces more data than the file contains"
    end
    return true
end

local function read_valid_dsk(path)
    local ok, err = validate_dsk_header(path)
    if not ok then
        error(err, 0)
    end
    dsk.init()
    dsk.verbose = false
    assert(dsk.read(path), "unable to read DSK")
end

local function span(text, fg, bold)
    return { text = text, fg = fg or "white", bg = "black", bold = bold or false }
end

local function line(...)
    return { ... }
end

local function pad_right(value, width)
    value = tostring(value or "")
    if #value >= width then
        return value:sub(1, width)
    end
    return value .. string.rep(" ", width - #value)
end

local function pad_left(value, width)
    value = tostring(value or "")
    if #value >= width then
        return value:sub(1, width)
    end
    return string.rep(" ", width - #value) .. value
end

local function block_list(entry)
    local out = {}
    local range_start = nil
    local previous = nil
    local function flush_range()
        if range_start == nil then
            return
        end
        if range_start == previous then
            table.insert(out, tostring(range_start))
        else
            table.insert(out, tostring(range_start) .. "-" .. tostring(previous))
        end
        range_start = nil
        previous = nil
    end

    for _, block in ipairs(entry.blocks or {}) do
        if range_start == nil then
            range_start = block
            previous = block
        elseif block == previous + 1 then
            previous = block
        else
            flush_range()
            range_start = block
            previous = block
        end
    end
    flush_range()
    return table.concat(out, " ")
end

local function catalog_rows()
    local rows = {}
    for _, entry in pairs(dsk.catalog or {}) do
        if type(entry) == "table" and entry.filename then
            table.insert(rows, entry)
        end
    end
    table.sort(rows, function(left, right)
        if left.filename == right.filename then
            return (left.numextension or 0) < (right.numextension or 0)
        end
        return left.filename < right.filename
    end)
    return rows
end

local function free_block_count()
    local free = 0
    local total = 0
    for _, available in pairs(dsk.freeblocks or {}) do
        total = total + 1
        if available then
            free = free + 1
        end
    end
    return free, total
end

local function render_dsk_directory(path, mode)
    if mode ~= "text" or not path:lower():match("%.dsk$") then
        return nil
    end

    read_valid_dsk(path)
    local catalog_ok, catalog_err = pcall(dsk.cat)

    local rows = {}
    if catalog_ok then
        rows = catalog_rows()
    end
    local free, total = free_block_count()
    local lines = {}
    table.insert(lines, line(span("Amstrad CPC DSK directory", "yellow", true)))
    table.insert(lines, line(span("Image: ", "gray"), span(basename(path), "white", true)))
    table.insert(lines, line(
        span("Format: ", "gray"),
        span("DSK v" .. tostring(dsk.version or "?"), "cyan"),
        span("  Tracks: ", "gray"),
        span(tostring(dsk.tracksnumber or "?"), "cyan"),
        span("  Sides: ", "gray"),
        span(tostring(dsk.sidesnumber or "?"), "cyan"),
        span("  Track size: ", "gray"),
        span(tostring(dsk.tracksize or "?"), "cyan")
    ))
    table.insert(lines, line(
        span("Entries: ", "gray"),
        span(tostring(#rows), "cyan"),
        span("  Free blocks: ", "gray"),
        span(tostring(free) .. "/" .. tostring(total), "cyan")
    ))
    if not catalog_ok then
        table.insert(lines, line(
            span("Catalog: ", "gray"),
            span(tostring(catalog_err or "not readable"), "red", true)
        ))
    end
    table.insert(lines, line(span("")))
    table.insert(lines, line(
        span("Usr ", "yellow", true),
        span("Ext ", "yellow", true),
        span("Hdr ", "yellow", true),
        span("LE            ", "yellow", true),
        span("Name         ", "yellow", true),
        span("Rec  ", "yellow", true),
        span("Blk  ", "yellow", true),
        span("Size   ", "yellow", true),
        span("Blocks", "yellow", true)
    ))
    table.insert(lines, line(span(string.rep("-", 90), "gray")))

    if #rows == 0 then
        if not catalog_ok then
            table.insert(lines,
            line(span("This image can be viewed as a disk image, but not entered as an AMSDOS archive.", "gray")))
            return lines
        end
        table.insert(lines, line(span("Empty directory", "gray")))
        return lines
    end

    local grouped = {}
    for _, entry in ipairs(rows) do
        grouped[entry.filename] = grouped[entry.filename] or {}
        table.insert(grouped[entry.filename], entry)
    end

    local header_status_by_name = {}
    local load_exec_by_name = {}
    for raw_name, entries in pairs(grouped) do
        local raw_data = read_catalog_file_raw(entries)
        if detect_amsdos_header(raw_name, raw_data) then
            header_status_by_name[raw_name] = amsdos_checksum_ok(raw_data) and "OK" or "TOL"
            load_exec_by_name[raw_name] = amsdos_load_exec(raw_data) or ""
        else
            header_status_by_name[raw_name] = ""
            load_exec_by_name[raw_name] = ""
        end
    end

    for _, entry in ipairs(rows) do
        local records = entry.nbrecords or 0
        local blocks = entry.blocks or {}
        local size = records * 128
        local hdr = header_status_by_name[entry.filename] or ""
        local le = load_exec_by_name[entry.filename] or ""
        table.insert(lines, line(
            span(pad_left(entry.user or 0, 3) .. " ", "white"),
            span(pad_left(entry.numextension or 0, 3) .. " ", "white"),
            span(pad_right(hdr, 4), hdr == "OK" and "green" or (hdr == "TOL" and "yellow" or "darkgray"), hdr ~= ""),
            span(pad_right(le, 14), "cyan"),
            span(pad_right(amsdos_name(entry.filename), 13), "lightcyan", true),
            span(pad_left(records, 3) .. "  ", "cyan"),
            span(pad_left(#blocks, 3) .. "  ", "cyan"),
            span(pad_left(size, 5) .. "  ", "green"),
            span(block_list(entry), "white")
        ))
    end

    return lines
end

local function amsdos_import_name(path)
    local name = basename(path):upper()
    local stem, ext = name:match("^([^%.]+)%.([^%.]+)$")
    if not stem then
        stem = name
        ext = "BIN"
    end
    stem = stem:gsub("[^A-Z0-9_%-]", "_"):sub(1, 8)
    ext = ext:gsub("[^A-Z0-9_%-]", "_"):sub(1, 3)
    if stem == "" then
        stem = "FILE"
    end
    if ext == "" then
        ext = "BIN"
    end
    return stem .. "." .. ext
end

local function user_folder_name(user_num)
    if user_num == nil or user_num == 0 then
        return nil
    end
    if user_num == 0xe5 then
        return ".Trash"
    end
    return string.format("User_%03d", user_num)
end

local function extract_dsk(path, destination)
    read_valid_dsk(path)
    dsk.cat()

    local grouped = {}
    for _, entry in pairs(dsk.catalog or {}) do
        if type(entry) == "table" and entry.filename then
            local user_num = entry.user or 0
            local group_key = tostring(user_num) .. ":" .. entry.filename
            if not grouped[group_key] then
                grouped[group_key] = {
                    raw_name = entry.filename,
                    user_num = user_num,
                    entries = {},
                }
            end
            table.insert(grouped[group_key].entries, entry)
        end
    end

    for _, group in pairs(grouped) do
        local raw_name = group.raw_name
        local entries = group.entries
        -- Sort entries by extension number to read them in order
        table.sort(entries, function(left, right)
            return (left.numextension or 0) < (right.numextension or 0)
        end)

        local full_data = read_catalog_file_raw(entries)
        local data = strip_amsdos_header(raw_name, full_data)

        local friendly_name = amsdos_name(raw_name)
        if friendly_name ~= "" then
            local out_dir = destination
            local user_folder = user_folder_name(group.user_num)
            if user_folder then
                out_dir = kkc.path_join(destination, user_folder)
            end

            -- Extract the user-friendly version (without header)
            kkc.write_file(kkc.path_join(out_dir, friendly_name), data)

            -- If AMSDOS header is detected, also extract the version with header
            if #data ~= #full_data then
                local amsd_name = friendly_name .. ".amsd"
                kkc.write_file(kkc.path_join(out_dir, amsd_name), full_data)
            end
        end
    end

    return true
end

local function normalize_tracks_for_write()
    for track = 0, (dsk.tracksnumber or 0) - 1 do
        for side = 0, (dsk.sidesnumber or 1) - 1 do
            local track_data = dsk.tracks and dsk.tracks[track] and dsk.tracks[track][side]
            if track_data and track_data.sector then
                local filler = string.char(track_data.filler or 0xe5)
                for sector = 0, (track_data.sectorsnumber or 0) - 1 do
                    local sector_data = track_data.sector[sector]
                    if sector_data and not sector_data.data then
                        local size = sector_data.size or track_data.sectorssize or 2
                        sector_data.data = string.rep(filler, 256 << (size - 1))
                    end
                end
            end
        end
    end
end

local function add_files_to_dsk(path, files)
    read_valid_dsk(path)
    dsk.cat()

    for _, source in ipairs(files) do
        local handle = assert(io.open(source, "rb"))
        handle:close()
        assert(
            dsk.saveexternalfile(source, amsdos_import_name(source), dsk.AMSDOS_FILETYPE_BINARY, 0x0000, 0x0000),
            "unable to add file to DSK"
        )
    end

    normalize_tracks_for_write()
    assert(dsk.write(path), "unable to write DSK")
    return true
end

kkc.register_archive_plugin({
    name = "amstrad_dsk",
    version = "1.0.0",
    description = "Amstrad CPC DSK archive plugin",
    mime_types = { "application/x-amstrad-cpc-dsk" },
    can_handle = function(path)
        return path:lower():match("%.dsk$") ~= nil
    end,
    extract = extract_dsk,
    add_files = add_files_to_dsk,
})

kkc.register_viewer_plugin({
    name = "amstrad_dsk_directory",
    version = "1.0.0",
    description = "Amstrad CPC DSK directory viewer",
    modes = { "text" },
    mime_types = { "application/x-amstrad-cpc-dsk" },
    render = render_dsk_directory,
})
