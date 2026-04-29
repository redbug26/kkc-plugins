local kkc = require("kkc")

local function span(text, fg, bold)
    return { text = text, fg = fg or "white", bg = "black", bold = bold or false }
end

local function line(...)
    return { ... }
end

local function basename(path)
    return path:match("([^/\\]+)$") or path
end

local function is_name_byte(byte)
    return (byte >= 0x41 and byte <= 0x5a)
        or (byte >= 0x30 and byte <= 0x39)
        or byte == 0x20
        or byte == 0x5f
        or byte == 0x2d
        or byte == 0x2e
end

local function amsdos_name_from_header(data)
    local bytes = {}
    for i = 2, 12 do
        local b = (data:byte(i) or 0) & 0x7f
        if not is_name_byte(b) then
            return nil
        end
        table.insert(bytes, string.char(b))
    end
    local raw = table.concat(bytes)
    local base = raw:sub(1, 8):gsub("%s+$", "")
    local ext = raw:sub(9, 11):gsub("%s+$", "")
    if base == "" then
        return nil
    end
    if ext == "" then
        return base
    end
    return base .. "." .. ext
end

local function read_all(path)
    local file = io.open(path, "rb")
    if not file then
        return nil, "unable to open file"
    end
    local data = file:read("*a") or ""
    file:close()
    return data
end

local function parse_amsdos(data)
    if #data < 128 then
        return nil, "file too small for AMSDOS header"
    end

    local user = data:byte(1) or 0xff
    if user > 31 then
        return nil, "invalid AMSDOS user number"
    end

    local display_name = amsdos_name_from_header(data)
    if not display_name then
        return nil, "invalid AMSDOS filename field"
    end

    local file_type = data:byte(19) or 0xff
    local protected = (file_type & 0x01) ~= 0
    local content_kind = (file_type >> 1) & 0x07
    local version = (file_type >> 4) & 0x0f
    local content_label = ({ [0] = "BASIC", [1] = "Binary", [2] = "Screen", [3] = "ASCII" })[content_kind] or "Unknown"

    local length = (data:byte(25) or 0) + (data:byte(26) or 0) * 256
    if length <= 0 then
        return nil, "invalid AMSDOS payload length"
    end

    local entry_address = (data:byte(27) or 0) + (data:byte(28) or 0) * 256
    local load_address = (data:byte(22) or 0) + (data:byte(23) or 0) * 256

    local real_length = (data:byte(65) or 0) + (data:byte(66) or 0) * 256 + (data:byte(67) or 0) * 65536

    local payload_start = 129
    local payload_end = math.min(#data, 128 + length)
    local payload_len = math.max(0, payload_end - payload_start + 1)

    local checksum = 0
    for i = 1, 67 do
        checksum = (checksum + (data:byte(i) or 0)) & 0xffff
    end
    local stored = (data:byte(68) or 0) + (data:byte(69) or 0) * 256

    return {
        user = user,
        display_name = display_name,
        file_type = file_type,
        protected = protected,
        content_kind = content_kind,
        content_label = content_label,
        version = version,
        load_address = load_address,
        declared_length = length,
        real_length = real_length,
        entry_address = entry_address,
        payload_len = payload_len,
        checksum = checksum,
        checksum_ok = checksum == stored,
        stored_checksum = stored,
    }
end

local function render_amsdos(path, mode)
    if mode ~= "text" then
        return nil
    end

    local data, err = read_all(path)
    if not data then
        return {
            line(span("AMSDOS file", "yellow", true)),
            line(span("File: ", "gray"), span(basename(path), "white", true)),
            line(span("Error: ", "gray"), span(err or "read error", "red", true)),
        }
    end

    local parsed, parse_err = parse_amsdos(data)
    if not parsed then
        return {
            line(span("AMSDOS file", "yellow", true)),
            line(span("File: ", "gray"), span(basename(path), "white", true)),
            line(span("Error: ", "gray"), span(parse_err or "invalid header", "red", true)),
        }
    end

    return {
        line(span("Amstrad AMSDOS header", "yellow", true)),
        line(span("File: ", "gray"), span(basename(path), "white", true)),
        line(span("Embedded name: ", "gray"), span(parsed.display_name, "lightcyan", true)),
        line(span("User: ", "gray"), span(tostring(parsed.user), "cyan")),
        line(span("Type: ", "gray"), span(parsed.content_label .. " (raw=" .. tostring(parsed.file_type) .. ")", "cyan")),
        line(span("Protected: ", "gray"),
            span(parsed.protected and "yes" or "no", parsed.protected and "yellow" or "green")),
        line(span("Version: ", "gray"), span(tostring(parsed.version), "cyan")),
        line(span("Exec address: ", "gray"), span(string.format("0x%04X", parsed.entry_address), "cyan")),
        line(span("Load address: ", "gray"), span(string.format("0x%04X", parsed.load_address), "cyan")),
        line(span("Logical length: ", "gray"), span(tostring(parsed.declared_length) .. " bytes", "green")),
        line(span("Real length: ", "gray"), span(tostring(parsed.real_length) .. " bytes", "green")),
        line(span("Available payload: ", "gray"), span(tostring(parsed.payload_len) .. " bytes", "green")),
        line(span("Checksum: ", "gray"), span(string.format("%04X", parsed.checksum), "white"),
            span(" / stored ", "gray"), span(string.format("%04X", parsed.stored_checksum), "white"),
            span(parsed.checksum_ok and "  OK" or "  mismatch", parsed.checksum_ok and "green" or "yellow", true)),
    }
end

kkc.register_viewer_plugin({
    name = "amsdos_viewer",
    version = "1.0.2",
    description = "Viewer for Amstrad AMSDOS files",
    modes = { "text" },
    mime_types = { "application/x-amstrad-cpc-amsdos" },
    render = render_amsdos,
})
