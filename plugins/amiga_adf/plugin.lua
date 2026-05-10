local kkc = require("kkc")

local BLOCK_SIZE = 512
local HASH_TABLE_SIZE = 72
local ST_ROOT = 1
local ST_USERDIR = 2
local ST_FILE = -3
local ST_SOFTLINK = 3
local ST_LINKDIR = 4
local ST_LINKFILE = -4

local function trim(text)
    return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function latin1_to_utf8(text)
    local out = {}
    for idx = 1, #(text or "") do
        local byte = text:byte(idx)
        if byte < 0x80 then
            out[#out + 1] = string.char(byte)
        else
            out[#out + 1] = string.char(0xC0 | (byte >> 6))
            out[#out + 1] = string.char(0x80 | (byte & 0x3F))
        end
    end
    return table.concat(out)
end

local function sanitize_component(name)
    local value = latin1_to_utf8(name or "")
    value = trim(value:gsub("[%z\r\n]", " "))
    value = value:gsub("[\\/:]", "_")
    value = value:gsub("[%c]", "_")
    value = value:gsub("^%.+$", "_")
    value = trim(value)
    if value == "" then
        return "unnamed"
    end
    return value
end

local function unique_component(raw_name, used)
    local base = sanitize_component(raw_name)
    if not used[base:lower()] then
        used[base:lower()] = 1
        return base
    end
    local idx = used[base:lower()] + 1
    used[base:lower()] = idx
    return string.format("%s (%d)", base, idx)
end

local function be_u32(data, offset)
    local b1, b2, b3, b4 = data:byte(offset + 1, offset + 4)
    if not b4 then
        return nil
    end
    return ((b1 or 0) << 24) | ((b2 or 0) << 16) | ((b3 or 0) << 8) | (b4 or 0)
end

local function be_i32(data, offset)
    local value = be_u32(data, offset)
    if not value then
        return nil
    end
    if value >= 0x80000000 then
        return value - 0x100000000
    end
    return value
end

local function read_bstr(data, length_offset, max_len)
    local len = data:byte(length_offset + 1) or 0
    len = math.min(len, max_len)
    if len <= 0 then
        return ""
    end
    return latin1_to_utf8(data:sub(length_offset + 2, length_offset + 1 + len))
end

local function read_cstr(data, offset, max_len)
    local raw = data:sub(offset + 1, offset + max_len)
    local zero = raw:find("\0", 1, true)
    if zero then
        raw = raw:sub(1, zero - 1)
    end
    return latin1_to_utf8(raw)
end

local function read_block(image, block_no)
    local start_pos = block_no * BLOCK_SIZE + 1
    local end_pos = start_pos + BLOCK_SIZE - 1
    if start_pos < 1 or end_pos > #image then
        return nil
    end
    return image:sub(start_pos, end_pos)
end

local function filesystem_label(boot_flags)
    local ffs = (boot_flags & 0x01) ~= 0
    local intl = (boot_flags & 0x02) ~= 0
    local dircache = (boot_flags & 0x04) ~= 0
    local parts = { ffs and "FFS" or "OFS" }
    if dircache then
        table.insert(parts, "DIRC")
    end
    if intl or dircache then
        table.insert(parts, "INTL")
    end
    return table.concat(parts, "/")
end

local function collect_file_block_pointers(image, header_block)
    local pointers = {}

    local function append_from_block(block)
        local count = be_u32(block, 8) or 0
        count = math.min(count, HASH_TABLE_SIZE)
        for idx = 0, count - 1 do
            local slot = HASH_TABLE_SIZE - 1 - idx
            local ptr = be_u32(block, 24 + slot * 4) or 0
            if ptr ~= 0 then
                table.insert(pointers, ptr)
            end
        end
    end

    append_from_block(header_block)
    local extension = be_u32(header_block, 504) or 0
    local seen = {}
    while extension ~= 0 and not seen[extension] do
        seen[extension] = true
        local ext_block = read_block(image, extension)
        if not ext_block then
            break
        end
        append_from_block(ext_block)
        extension = be_u32(ext_block, 504) or 0
    end

    return pointers
end

local function extract_ffs_file(image, header_block, size)
    if size <= 0 then
        return ""
    end

    local out = {}
    local remaining = size
    for _, ptr in ipairs(collect_file_block_pointers(image, header_block)) do
        if remaining <= 0 then
            break
        end
        local data_block = read_block(image, ptr)
        if data_block then
            local chunk = data_block:sub(1, math.min(BLOCK_SIZE, remaining))
            table.insert(out, chunk)
            remaining = remaining - #chunk
        end
    end

    return table.concat(out):sub(1, size)
end

local function extract_ofs_file(image, header_block, size)
    if size <= 0 then
        return ""
    end

    local out = {}
    local remaining = size
    local pointers = collect_file_block_pointers(image, header_block)

    if #pointers == 0 then
        local next_block = be_u32(header_block, 16) or 0
        local seen = {}
        while next_block ~= 0 and not seen[next_block] do
            seen[next_block] = true
            table.insert(pointers, next_block)
            local data_block = read_block(image, next_block)
            if not data_block then
                break
            end
            next_block = be_u32(data_block, 16) or 0
        end
    end

    for _, ptr in ipairs(pointers) do
        if remaining <= 0 then
            break
        end
        local data_block = read_block(image, ptr)
        if data_block then
            local data_size = math.min(be_u32(data_block, 12) or 0, BLOCK_SIZE - 24, remaining)
            if data_size > 0 then
                table.insert(out, data_block:sub(25, 24 + data_size))
                remaining = remaining - data_size
            end
        end
    end

    return table.concat(out):sub(1, size)
end

local function parse_entry(block_no, block)
    return {
        block_no = block_no,
        sec_type = be_i32(block, 508) or 0,
        name = read_bstr(block, 432, 30),
        size = be_u32(block, 324) or 0,
        real_entry = be_u32(block, 468) or 0,
    }
end

local function list_directory_entries(image, dir_block)
    local entries = {}
    local seen = {}
    for idx = 0, HASH_TABLE_SIZE - 1 do
        local ptr = be_u32(dir_block, 24 + idx * 4) or 0
        while ptr ~= 0 and not seen[ptr] do
            seen[ptr] = true
            local entry_block = read_block(image, ptr)
            if not entry_block then
                break
            end
            table.insert(entries, parse_entry(ptr, entry_block))
            ptr = be_u32(entry_block, 496) or 0
        end
    end

    table.sort(entries, function(a, b)
        local an = a.name:lower()
        local bn = b.name:lower()
        if an == bn then
            return a.block_no < b.block_no
        end
        return an < bn
    end)
    return entries
end

local function write_placeholder(destination, name, text, used)
    local file_name = unique_component(name, used)
    kkc.write_file(kkc.path_join(destination, file_name), text)
end

local function extract_file_entry(image, entry_block, entry, destination, used, boot_flags)
    local file_name = unique_component(entry.name, used)
    local output_path = kkc.path_join(destination, file_name)
    local is_ffs = (boot_flags & 0x01) ~= 0
    local content
    if is_ffs then
        content = extract_ffs_file(image, entry_block, entry.size)
    else
        content = extract_ofs_file(image, entry_block, entry.size)
    end
    kkc.write_file(output_path, content)
end

local function extract_directory(image, dir_block_no, destination, state)
    if state.active_dirs[dir_block_no] then
        return
    end
    state.active_dirs[dir_block_no] = true

    local dir_block = read_block(image, dir_block_no)
    if not dir_block then
        state.active_dirs[dir_block_no] = nil
        return
    end

    local used = {}
    for _, entry in ipairs(list_directory_entries(image, dir_block)) do
        local entry_block = read_block(image, entry.block_no)
        if entry_block then
            if entry.sec_type == ST_USERDIR then
                local dir_name = unique_component(entry.name, used)
                local child_path = kkc.path_join(destination, dir_name)
                kkc.create_dir_all(child_path)
                extract_directory(image, entry.block_no, child_path, state)
            elseif entry.sec_type == ST_FILE then
                extract_file_entry(image, entry_block, entry, destination, used, state.boot_flags)
            elseif entry.sec_type == ST_SOFTLINK then
                local target = read_cstr(entry_block, 24, BLOCK_SIZE - 224 - 1)
                write_placeholder(
                    destination,
                    entry.name .. ".link.txt",
                    "Soft link: " .. entry.name .. "\nTarget: " .. target .. "\n",
                    used
                )
            elseif entry.sec_type == ST_LINKFILE or entry.sec_type == ST_LINKDIR then
                write_placeholder(
                    destination,
                    entry.name .. ".link.txt",
                    string.format(
                        "Hard link: %s\nTarget block: %d\n",
                        entry.name,
                        entry.real_entry or 0
                    ),
                    used
                )
            end
        end
    end

    state.active_dirs[dir_block_no] = nil
end

local function extract_adf(path, destination)
    local file = assert(io.open(path, "rb"))
    local image = file:read("*all")
    file:close()

    if #image < BLOCK_SIZE * 3 or (#image % BLOCK_SIZE) ~= 0 then
        error("invalid ADF image size", 0)
    end
    if image:sub(1, 3) ~= "DOS" then
        error("unsupported ADF image: missing DOS boot signature", 0)
    end

    local total_blocks = #image // BLOCK_SIZE
    local boot_flags = image:byte(4) or 0

    -- Build a list of candidate root block positions to try in order.
    local candidates = {}
    local hint = be_u32(image, 8) or 0
    if hint > 1 and hint < total_blocks then
        table.insert(candidates, hint)
    end
    -- Standard Amiga formula: floor((numReserved + highKey) / 2)
    -- For DD (1760 blocks): floor((2 + 1759) / 2) = 880
    table.insert(candidates, math.floor(total_blocks / 2))
    -- Hardcoded well-known positions as last-resort fallbacks
    if total_blocks >= 1760 then table.insert(candidates, 880) end
    if total_blocks >= 3520 then table.insert(candidates, 1760) end

    local root_block, root_block_no
    for _, candidate in ipairs(candidates) do
        local block = read_block(image, candidate)
        if block and (be_i32(block, 508) or 0) == ST_ROOT then
            root_block = block
            root_block_no = candidate
            break
        end
    end
    -- Last resort: scan all blocks for one with sec_type == ST_ROOT
    if not root_block then
        for i = 2, total_blocks - 1 do
            local block = read_block(image, i)
            if block and (be_i32(block, 508) or 0) == ST_ROOT and (be_i32(block, 0) or 0) == 2 then
                root_block = block
                root_block_no = i
                break
            end
        end
    end

    -- No AmigaDOS filesystem found: likely a custom/game disk with a proprietary layout.
    -- Extract a descriptive README instead of failing.
    if not root_block then
        local bootcode = read_cstr(image, 4, 4)
        local info_lines = {
            "Amiga ADF disk image (custom / non-standard filesystem)",
            "",
            "File: " .. path,
            "Filesystem: custom (no AmigaDOS OFS/FFS root block found)",
            "Blocks: " .. tostring(total_blocks),
            "Boot signature: DOS" .. bootcode,
            "",
            "This disk uses a custom bootblock or proprietary layout and",
            "cannot be browsed as a standard AmigaDOS filesystem.",
        }
        kkc.write_file(kkc.path_join(destination, "README.txt"), table.concat(info_lines, "\n") .. "\n")
        return true
    end

    local volume_name = read_bstr(root_block, 432, 30)
    local info_lines = {
        "Amiga ADF disk image",
        "",
        "File: " .. path,
        "Volume: " .. (volume_name ~= "" and volume_name or "(unnamed)"),
        "Filesystem: " .. filesystem_label(boot_flags),
        "Blocks: " .. tostring(total_blocks),
        "Root block: " .. tostring(root_block_no),
        "",
        "Links are exported as small text placeholders.",
    }
    kkc.write_file(kkc.path_join(destination, "README.txt"), table.concat(info_lines, "\n") .. "\n")

    extract_directory(image, root_block_no, destination, {
        boot_flags = boot_flags,
        active_dirs = {},
    })

    return true
end

kkc.register_archive_plugin({
    extract = extract_adf,
})