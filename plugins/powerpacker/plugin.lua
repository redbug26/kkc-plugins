-- PowerPacker decrunch plugin for KKC
-- Supports PP20 (PowerPacker 2.0) and PP11 (PowerPacker 1.1) compressed Amiga files.
--
-- Algorithm ported from PP-Tools (Aminet) by david tritscher,
-- C++ version by Ilkka Prusi (2011).  Unlimited distribution.

local kkc = require("kkc")

-- Build a bit-reversal lookup table (reverses all 8 bits in a byte)
local rev_table = {}
for a = 0, 255 do
    local b = a
    b = ((b & 0x0f) << 4) | ((b >> 4) & 0x0f)
    b = ((b & 0x33) << 2) | ((b >> 2) & 0x33)
    b = ((b & 0x55) << 1) | ((b >> 1) & 0x55)
    rev_table[a] = b
end

-- Decompress a PowerPacker (PP20 / PP11) file.
-- Returns the decompressed string, or nil + error message on failure.
local function pp_decompress(data)
    if #data < 12 then
        return nil, "file too short"
    end

    local magic = data:sub(1, 4)
    if magic ~= "PP20" and magic ~= "PP11" then
        return nil, "not a PowerPacker file"
    end

    -- Efficiency bytes are at file offsets 4-7 (1-based: bytes 5-8)
    local ptrbit_2 = data:byte(5)
    local ptrbit_3 = data:byte(6)
    local ptrbit_4 = data:byte(7)
    local ptrbit_5 = data:byte(8)

    -- Validate known efficiency combinations
    local valid = (ptrbit_2 == 9 and ptrbit_3 == 9  and ptrbit_4 == 9  and ptrbit_5 == 9)  or
                  (ptrbit_2 == 9 and ptrbit_3 == 10 and ptrbit_4 == 10 and ptrbit_5 == 10) or
                  (ptrbit_2 == 9 and ptrbit_3 == 10 and ptrbit_4 == 11 and ptrbit_5 == 11) or
                  (ptrbit_2 == 9 and ptrbit_3 == 10 and ptrbit_4 == 12 and ptrbit_5 == 12) or
                  (ptrbit_2 == 9 and ptrbit_3 == 10 and ptrbit_4 == 12 and ptrbit_5 == 13)
    if not valid then
        return nil, "bad metadata (unknown efficiency)"
    end

    local n = #data

    -- The last 4 bytes of the file hold uncompressed size (3 bytes BE) + bitrot (1 byte).
    local sz_hi  = data:byte(n - 3)
    local sz_mid = data:byte(n - 2)
    local sz_lo  = data:byte(n - 1)
    local bitrot = data:byte(n)

    local out_size = (sz_hi << 16) | (sz_mid << 8) | sz_lo
    if out_size == 0 then
        return nil, "bad uncompressed size"
    end
    if bitrot >= 32 then
        return nil, "bad bitrot"
    end

    -- Compressed payload: bytes 9..n-4 (1-based, inclusive)
    -- (first 8 bytes are header; last 4 bytes are the size/bitrot trailer)
    local in_start = 9
    local in_end   = n - 4     -- inclusive
    local in_size  = in_end - in_start + 1

    if in_size <= 0 or in_size % 4 ~= 0 then
        return nil, "bad compressed size"
    end

    -- ------------------------------------------------------------------ --
    -- Decompression state
    -- The algorithm reads the compressed data BACKWARDS and writes the
    -- output BACKWARDS (from end to start of the output buffer).
    -- ------------------------------------------------------------------ --

    -- in_pos: index into `data` of the next byte to read (decrements)
    -- Initialise to in_end; each byte is consumed by decrementing first.
    local in_pos = in_end

    -- out: output buffer (1-indexed array of byte values 0..255)
    local out = {}

    -- out_pos: index of the next slot to write in `out` (decrements from out_size+1)
    local out_pos = out_size + 1

    -- code: 32-bit accumulator of bits read from the input
    -- shift: number of "free" (unused) slots at the bottom of `code`
    --        invariant: the top (32-shift) bits of code hold unread bits
    local code  = 0
    local shift = 32

    -- Ensure at least `x` bits are loaded into the top of `code`.
    local function peek(x)
        while shift > 32 - x do
            if in_pos < in_start then
                return false
            end
            shift = shift - 8
            local byte_val = rev_table[data:byte(in_pos)]
            in_pos = in_pos - 1
            -- Place the reversed byte into `code` at bit position `shift`
            code = (code + (byte_val << shift)) & 0xffffffff
        end
        return true
    end

    -- Consume `x` bits from the top of `code`.
    local function shl(x)
        shift = shift + x
        code  = (code << x) & 0xffffffff
    end

    -- ------------------------------------------------------------------ --
    -- Initialise: skip `bitrot` bits from the very end of the stream
    -- ------------------------------------------------------------------ --
    if bitrot > 0 then
        if not peek(bitrot) then
            return nil, "truncated data (bitrot)"
        end
        shl(bitrot)
    end

    -- Read the "protect" bit.  This bit determines which value of the
    -- literal/match flag means "literal" for this particular file.
    -- The bit is NOT consumed here; the main loop will read it again.
    if not peek(1) then
        return nil, "truncated data (protect)"
    end
    local protect = (code >> 31) & 1

    -- ------------------------------------------------------------------ --
    -- Main decompression loop
    -- ------------------------------------------------------------------ --
    while true do
        -- Read the literal/match flag (1 bit)
        if not peek(3) then
            return nil, "truncated data"
        end
        local bit = (code >> 31) & 1
        shl(1)

        if bit == protect then
            -- ---- Literal run ----------------------------------------- --
            -- Read the run length: 2 bits give 1..4; if 4, keep reading.
            local len = ((code >> 30) & 3) + 1
            shl(2)

            if len == 4 then
                repeat
                    if not peek(2) then
                        return nil, "truncated data (literal length)"
                    end
                    bit = (code >> 30) & 3
                    shl(2)
                    len = len + bit
                until bit ~= 3
            end

            -- Copy `len` literal bytes into the output (backwards)
            for _ = 1, len do
                if not peek(8) then
                    return nil, "truncated data (literal byte)"
                end
                out_pos = out_pos - 1
                out[out_pos] = (code >> 24) & 0xff
                shl(8)
            end

            if out_pos == 1 then
                break
            end
        end

        -- ---- Back-reference (match) ----------------------------------- --
        if not peek(3) then
            return nil, "truncated data (match header)"
        end

        -- BitSwitch: decode match length and offset-width from top 3 bits
        local top3 = (code >> 29) & 7
        local match_len, ptr_bits
        if top3 == 2 or top3 == 3 then
            shl(2); match_len = 3; ptr_bits = ptrbit_3
        elseif top3 == 4 or top3 == 5 then
            shl(2); match_len = 4; ptr_bits = ptrbit_4
        elseif top3 == 6 then
            shl(3); match_len = 5; ptr_bits = 7
        elseif top3 == 7 then
            shl(3); match_len = 5; ptr_bits = ptrbit_5
        else
            shl(2); match_len = 2; ptr_bits = ptrbit_2
        end

        -- Read the back-reference offset (ptr_bits bits)
        if not peek(ptr_bits) then
            return nil, "truncated data (match offset)"
        end
        local ptr = ((code >> (32 - ptr_bits)) & 0xffffffff) + 1
        shl(ptr_bits)

        -- Extended length: if match_len == 5, keep reading 3-bit chunks
        if match_len == 5 then
            repeat
                if not peek(3) then
                    return nil, "truncated data (match length ext)"
                end
                bit = (code >> 29) & 7
                shl(3)
                match_len = match_len + bit
            until bit ~= 7
        end

        -- Copy `match_len` bytes from the already-decoded region.
        -- `ptr` bytes forward from the current write head = already written.
        local str_pos = out_pos + ptr
        for _ = 1, match_len do
            str_pos  = str_pos  - 1
            out_pos  = out_pos  - 1
            out[out_pos] = out[str_pos] or 0
        end

        if out_pos == 1 then
            break
        end
    end

    -- ------------------------------------------------------------------ --
    -- Build the output string
    -- ------------------------------------------------------------------ --
    local chars = {}
    for i = 1, out_size do
        chars[i] = string.char(out[i] or 0)
    end
    return table.concat(chars)
end

-- ------------------------------------------------------------------ --
-- Derive an output filename from the packed file path.
-- PowerPacker files often have no extension or carry a .pp / .pp2 suffix.
-- ------------------------------------------------------------------ --
local function output_name(path)
    local basename = path:match("[^/\\]+$") or "output"
    -- Strip common PowerPacker suffixes
    local stripped = basename:match("^(.+)%.[Pp][Pp]2?$")
    if stripped and #stripped > 0 then
        return stripped
    end
    return basename .. ".unpacked"
end

-- ------------------------------------------------------------------ --
-- Plugin registration
-- ------------------------------------------------------------------ --
kkc.register_archive_plugin({
    name        = "powerpacker",
    version     = "1.0.0",
    description = "Decrunch Amiga PowerPacker files (PP20/PP11)",
    mime_types  = { "application/x-powerpacker" },

    extract = function(path, destination)
        local f = io.open(path, "rb")
        if not f then
            error("PowerPacker: cannot open file: " .. path)
        end
        local data = f:read("*a")
        f:close()

        local decompressed, err = pp_decompress(data)
        if not decompressed then
            error("PowerPacker: " .. (err or "decompression failed"))
        end

        local out_file = kkc.path_join(destination, output_name(path))
        kkc.write_file(out_file, decompressed)
        return true
    end,
})
