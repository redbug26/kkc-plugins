local kkc = require("kkc")

local sectors_per_track = {
    21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21,
    19, 19, 19, 19, 19, 19, 19,
    18, 18, 18, 18, 18, 18,
    17, 17, 17, 17, 17,
}

local file_types = {
    [0] = "del",
    [1] = "seq",
    [2] = "prg",
    [3] = "usr",
    [4] = "rel",
}

local petscii_unicode = {
    -- Control
    [0x00] = "",
    [0x0d] = "\n",

    -- Arrows / symbols
    [0x1c] = "←",
    [0x1d] = "→",
    [0x1e] = "↑",
    [0x1f] = "↓",

    -- Basic replacements
    [0x40] = "@",
    [0x5b] = "[",
    [0x5c] = "£",
    [0x5d] = "]",
    [0x5e] = "↑",
    [0x5f] = "←",

    -- Box drawing (PETSCII graphics)
    [0x60] = "─",
    [0x61] = "│",
    [0x62] = "┌",
    [0x63] = "┐",
    [0x64] = "└",
    [0x65] = "┘",
    [0x66] = "├",
    [0x67] = "┤",
    [0x68] = "┬",
    [0x69] = "┴",
    [0x6a] = "┼",

    -- Corners / variants
    [0x6b] = "╭",
    [0x6c] = "╮",
    [0x6d] = "╰",
    [0x6e] = "╯",

    -- Misc symbols
    [0x6f] = "●",
    [0x70] = "○",
    [0x71] = "◆",
    [0x72] = "◇",
    [0x73] = "■",
    [0x74] = "□",

    -- Greek / math
    [0x7e] = "π",

    -- Shades / blocks
    [0xa0] = " ",
    [0xa1] = "▌",
    [0xa2] = "▄",
    [0xa3] = "▔",
    [0xa4] = "▁",
    [0xa5] = "▏",
    [0xa6] = "▒",
    [0xa7] = "▕",
    [0xa8] = "▖",
    [0xa9] = "▗",
    [0xaa] = "▘",
    [0xab] = "▝",
    [0xac] = "▚",
    [0xad] = "▞",
    [0xae] = "▙",
    [0xaf] = "▛",
    [0xb0] = "▜",
    [0xb1] = "▟",

    -- Box drawing extended
    [0xb2] = "┌",
    [0xb3] = "│",
    [0xb4] = "┐",
    [0xb5] = "├",
    [0xb6] = "┤",
    [0xb7] = "└",
    [0xb8] = "┘",
    [0xb9] = "┬",
    [0xba] = "┴",
    [0xbb] = "┼",

    -- Full blocks
    [0xdb] = "█",
    [0xdc] = "▄",
    [0xdd] = "▌",
    [0xde] = "▐",
    [0xdf] = "▀",
}

local function sector_offset(track, sector)
    assert(track >= 1 and track <= #sectors_per_track, "invalid D64 track")
    assert(sector >= 0 and sector < sectors_per_track[track], "invalid D64 sector")

    local sectors = sector
    for idx = 1, track - 1 do
        sectors = sectors + sectors_per_track[idx]
    end
    return sectors * 256 + 1
end

local function read_sector(image, track, sector)
    local offset = sector_offset(track, sector)
    local data = image:sub(offset, offset + 255)
    assert(#data == 256, "truncated D64 image")
    return data
end

local function petscii_char(byte)
    if not byte or byte == 0xa0 or byte == 0x00 then
        return ""
    end
    if petscii_unicode[byte] then
        return petscii_unicode[byte]
    end
    if byte >= 0xc1 and byte <= 0xda then
        return string.char(byte - 0x80)
    end
    if byte >= 0x01 and byte <= 0x1a then
        return string.char(byte + 0x40)
    end
    if byte >= 0x81 and byte <= 0x9a then
        return string.char(byte - 0x40)
    end
    if byte >= 0x41 and byte <= 0x5a then
        return string.char(byte)
    end
    if byte >= 0x61 and byte <= 0x7a then
        return string.char(byte)
    end
    if byte >= 0x30 and byte <= 0x39 then
        return string.char(byte)
    end
    if byte >= 0x20 and byte <= 0x3f then
        return string.char(byte)
    end
    return "�"
end

local function petscii_filename(raw)
    local out = {}
    for idx = 1, #raw do
        local ch = petscii_char(raw:byte(idx))
        if ch ~= "" then
            if ch == "/" or ch == "\\" or ch == ":" then
                ch = "_"
            end
            table.insert(out, ch)
        end
    end
    local name = table.concat(out):gsub("%s+$", "")
    if name == "" then
        return "unnamed"
    end
    return name
end

local function petscii_text(raw)
    local out = {}
    for idx = 1, #raw do
        local ch = petscii_char(raw:byte(idx))
        if ch ~= "" then
            table.insert(out, ch)
        end
    end
    local text = table.concat(out):gsub("%s+$", "")
    if text == "" then
        return "-"
    end
    return text
end

local function span(text, fg, bold)
    return { text = text, fg = fg or "white", bg = "black", bold = bold or false }
end

local function line(...)
    return { ... }
end

local function text_len(value)
    return utf8.len(value) or #value
end

local function pad_right(value, width)
    value = tostring(value or "")
    local len = text_len(value)
    if len >= width then
        return value
    end
    return value .. string.rep(" ", width - len)
end

local function pad_left(value, width)
    value = tostring(value or "")
    local len = text_len(value)
    if len >= width then
        return value
    end
    return string.rep(" ", width - len) .. value
end

local function read_image(path)
    local file = assert(io.open(path, "rb"))
    local image = file:read("*all")
    file:close()
    assert(#image >= 174848, "D64 image is too small")
    return image
end

local function unique_name(used, name)
    if not used[name] then
        used[name] = true
        return name
    end

    local stem, ext = name:match("^(.*)(%.[^%.]+)$")
    if not stem then
        stem = name
        ext = ""
    end

    local idx = 2
    while true do
        local candidate = string.format("%s_%d%s", stem, idx, ext)
        if not used[candidate] then
            used[candidate] = true
            return candidate
        end
        idx = idx + 1
    end
end

local function read_file(image, start_track, start_sector)
    local chunks = {}
    local track = start_track
    local sector = start_sector
    local visited = {}

    while track ~= 0 do
        local key = tostring(track) .. "/" .. tostring(sector)
        assert(not visited[key], "cyclic D64 file sector chain")
        visited[key] = true

        local data = read_sector(image, track, sector)
        local next_track = data:byte(1) or 0
        local next_sector = data:byte(2) or 0

        if next_track == 0 then
            local last = math.max(2, math.min(256, next_sector))
            table.insert(chunks, data:sub(3, last))
            break
        end

        table.insert(chunks, data:sub(3))
        track = next_track
        sector = next_sector
    end

    return table.concat(chunks)
end

local function read_directory(image, include_deleted)
    local entries = {}
    local track = 18
    local sector = 1
    local visited = {}

    while track ~= 0 do
        local key = tostring(track) .. "/" .. tostring(sector)
        assert(not visited[key], "cyclic D64 directory sector chain")
        visited[key] = true

        local data = read_sector(image, track, sector)
        for slot = 0, 7 do
            local base = 2 + slot * 32
            local raw_type = data:byte(base + 1) or 0
            local type_id = raw_type & 0x07
            local start_track = data:byte(base + 2) or 0
            local start_sector = data:byte(base + 3) or 0
            local size_lo = data:byte(base + 30) or 0
            local size_hi = data:byte(base + 31) or 0

            if type_id ~= 0 or include_deleted then
                local raw_name = data:sub(base + 4, base + 19)
                local type_name = file_types[type_id] or "file"
                table.insert(entries, {
                    name = petscii_filename(raw_name) .. "." .. type_name,
                    display_name = petscii_text(raw_name),
                    type = type_name,
                    raw_type = raw_type,
                    closed = (raw_type & 0x80) ~= 0,
                    locked = (raw_type & 0x40) ~= 0,
                    track = start_track,
                    sector = start_sector,
                    size_blocks = size_lo + size_hi * 256,
                })
            end
        end

        track = data:byte(1) or 0
        sector = data:byte(2) or 0
    end

    return entries
end

local function disk_info(image)
    local bam = read_sector(image, 18, 0)
    return {
        dir_track = bam:byte(1) or 18,
        dir_sector = bam:byte(2) or 1,
        dos_version = string.char(bam:byte(3) or 0),
        name = petscii_text(bam:sub(145, 160)),
        id = petscii_text(bam:sub(163, 164)),
        dos_type = petscii_text(bam:sub(166, 167)),
    }
end

local function free_block_count(image)
    local bam = read_sector(image, 18, 0)
    local free = 0
    for track = 1, 35 do
        free = free + (bam:byte(4 + (track - 1) * 4 + 1) or 0)
    end
    return free
end

local function block_list(entry)
    if (entry.track or 0) == 0 then
        return "-"
    end
    return tostring(entry.track) .. "/" .. tostring(entry.sector or 0)
end

local function c64_type_label(entry)
    local prefix = entry.closed and " " or "*"
    local suffix = entry.locked and "<" or " "
    return prefix .. (entry.type or "file"):upper() .. suffix
end

local function c64_file_line(entry)
    local left = pad_left(entry.size_blocks or 0, 5) .. " "
    local quoted = '"' .. entry.display_name .. '"'
    local name_field = pad_right(quoted, 19)
    return left .. name_field .. c64_type_label(entry)
end

local function c64_header_line(info)
    local disk_name = pad_right(info.name, 16)
    local disk_id = pad_right(info.id, 2)
    local dos_type = pad_right(info.dos_type, 2)
    return '    0 "' .. disk_name .. '" ' .. disk_id .. " " .. dos_type
end

local function render_d64_directory(path, mode)
    if mode ~= "text" or not path:lower():match("%.d64$") then
        return nil
    end

    local image = read_image(path)
    local info = disk_info(image)
    local entries = read_directory(image, true)
    local free_blocks = free_block_count(image)

    local lines = {}
    table.insert(lines, line(span("Commodore 64 D64 directory", "yellow", true)))
    table.insert(lines, line(span('LOAD"$",8', "gray"), span("  ; LIST", "gray")))
    table.insert(lines, line(span(c64_header_line(info), "lightcyan", true)))
    for _, entry in ipairs(entries) do
        table.insert(lines, line(span(c64_file_line(entry), "white")))
    end
    table.insert(lines, line(span(pad_left(free_blocks, 5) .. " BLOCKS FREE.", "lightgreen", true)))
    table.insert(lines, line(span("")))
    table.insert(lines, line(
        span("Disk: ", "gray"),
        span(info.name, "white", true),
        span("  ID: ", "gray"),
        span(info.id, "cyan"),
        span("  DOS: ", "gray"),
        span(info.dos_type, "cyan")
    ))
    table.insert(lines, line(
        span("Directory chain: ", "gray"),
        span(tostring(info.dir_track) .. "/" .. tostring(info.dir_sector), "cyan"),
        span("  Entries: ", "gray"),
        span(tostring(#entries), "cyan"),
        span("  Free blocks: ", "gray"),
        span(tostring(free_blocks), "green")
    ))

    table.insert(lines, line(span("")))
    table.insert(lines, line(span("Start sectors", "yellow", true)))
    for _, entry in ipairs(entries) do
        table.insert(lines, line(
            span(pad_right(block_list(entry), 6), "cyan"),
            span("  ", "white"),
            span(entry.display_name, "white", true)
        ))
    end

    return lines
end

local function extract_d64(path, destination)
    local image = read_image(path)

    local used = {}
    for _, entry in ipairs(read_directory(image, false)) do
        local name = unique_name(used, entry.name)
        local content = read_file(image, entry.track, entry.sector)
        kkc.write_file(kkc.path_join(destination, name), content)
    end

    return true
end

kkc.register_archive_plugin({
    name = "commodore_d64",
    version = "1.0.0",
    description = "Commodore 64 D64 disk image plugin",
    mime_types = { "application/x-c64-d64" },
    can_handle = function(path)
        return path:lower():match("%.d64$") ~= nil
    end,
    extract = extract_d64,
})

kkc.register_viewer_plugin({
    name = "commodore_d64_directory",
    version = "1.0.0",
    description = "Commodore 64 D64 directory viewer",
    modes = { "text" },
    mime_types = { "application/x-c64-d64" },
    render = render_d64_directory,
})
