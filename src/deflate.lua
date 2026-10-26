-- deflate.lua - raw DEFLATE (RFC 1951) for strings the Lua sandbox can round-trip.
--
-- No zlib header, no gzip header, no preset dictionary. compress() writes one
-- final dynamic-Huffman block. decompress() reads a raw deflate stream: stored,
-- fixed-Huffman, and dynamic-Huffman blocks, through the block marked final.
--
-- Bit packing follows the RFC, including the part that is easy to get backwards:
-- bits are stored least-significant-bit first inside each byte, but Huffman code
-- bits go out most-significant-bit first. Extra bits on length and distance codes
-- are least-significant-bit first. A codec that flips this still round-trips
-- through itself and is rejected by every other inflater.
--
-- compress.lua is the only caller. The paste token is raw deflate plus a prefix.

local Deflate = {}

-- Inflate refuses to grow an output past this. A hostile block can request a
-- very large expansion from a small input; the cap turns that into an error
-- instead of an unbounded allocation. Raise it if a real payload outgrows it.
Deflate.MAX_OUTPUT = 1048576

local WINDOW = 32768
local MIN_MATCH = 3
local MAX_MATCH = 258
-- Search depth and the lazy-match cutoff. Measured against a full global alert
-- export: a deeper chain changed the compressed size by a few bytes, and lazy
-- matching only paid off when the current match was still short.
local MAX_CHAIN = 128
local LAZY_BELOW = 32
local HASH_BITS = 15
local HASH_SIZE = 1 << HASH_BITS

-- Length and distance alphabets (RFC 1951 section 3.2.5). Each entry is
-- { base, extra_bits }. Length code 257 is index 1; distance code 0 is index 1.
local LEN_BASE = {
    { 3, 0 }, { 4, 0 }, { 5, 0 }, { 6, 0 }, { 7, 0 }, { 8, 0 }, { 9, 0 }, { 10, 0 },
    { 11, 1 }, { 13, 1 }, { 15, 1 }, { 17, 1 },
    { 19, 2 }, { 23, 2 }, { 27, 2 }, { 31, 2 },
    { 35, 3 }, { 43, 3 }, { 51, 3 }, { 59, 3 },
    { 67, 4 }, { 83, 4 }, { 99, 4 }, { 115, 4 },
    { 131, 5 }, { 163, 5 }, { 195, 5 }, { 227, 5 },
    { 258, 0 },
}

local DIST_BASE = {
    { 1, 0 }, { 2, 0 }, { 3, 0 }, { 4, 0 },
    { 5, 1 }, { 7, 1 },
    { 9, 2 }, { 13, 2 },
    { 17, 3 }, { 25, 3 },
    { 33, 4 }, { 49, 4 },
    { 65, 5 }, { 97, 5 },
    { 129, 6 }, { 193, 6 },
    { 257, 7 }, { 385, 7 },
    { 513, 8 }, { 769, 8 },
    { 1025, 9 }, { 1537, 9 },
    { 2049, 10 }, { 3073, 10 },
    { 4097, 11 }, { 6145, 11 },
    { 8193, 12 }, { 12289, 12 },
    { 16385, 13 }, { 24577, 13 },
}

-- Order in which dynamic blocks transmit code-length code lengths.
local CL_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

--------------------------------------------------------------------------------
-- Bit I/O
--------------------------------------------------------------------------------

local function writer_new()
    return { parts = {}, acc = 0, n = 0 }
end

local function put_lsb(w, value, bits)
    if bits == 0 then return end
    w.acc = w.acc | ((value & ((1 << bits) - 1)) << w.n)
    w.n = w.n + bits
    while w.n >= 8 do
        w.parts[#w.parts + 1] = string.char(w.acc & 0xFF)
        w.acc = w.acc >> 8
        w.n = w.n - 8
    end
end

-- Huffman codes: most-significant bit of `value` is the next bit on the stream.
local function put_msb(w, value, bits)
    for i = bits - 1, 0, -1 do
        put_lsb(w, (value >> i) & 1, 1)
    end
end

local function writer_finish(w)
    if w.n > 0 then
        w.parts[#w.parts + 1] = string.char(w.acc & 0xFF)
    end
    return table.concat(w.parts)
end

local function reader_new(data)
    return { data = data, pos = 1, acc = 0, n = 0, consumed = 0 }
end

local function pull(r, bits)
    while r.n < bits do
        if r.pos > #r.data then
            error("Truncated deflate stream.")
        end
        local b = r.data:byte(r.pos)
        r.pos = r.pos + 1
        r.acc = r.acc | (b << r.n)
        r.n = r.n + 8
    end
end

local function get(r, bits)
    if bits == 0 then return 0 end
    pull(r, bits)
    local v = r.acc & ((1 << bits) - 1)
    r.acc = r.acc >> bits
    r.n = r.n - bits
    r.consumed = r.consumed + bits
    return v
end

-- Look at the next `bits` without consuming them. Missing bits past the end of
-- the buffer are read as 0, which is safe only because the caller rejects a
-- code longer than the bits actually buffered (see read_symbol).
local function peek(r, bits)
    while r.n < bits and r.pos <= #r.data do
        local b = r.data:byte(r.pos)
        r.pos = r.pos + 1
        r.acc = r.acc | (b << r.n)
        r.n = r.n + 8
    end
    return r.acc & ((1 << bits) - 1)
end

local function drop(r, bits)
    if bits > r.n then
        error("Truncated deflate stream.")
    end
    r.acc = r.acc >> bits
    r.n = r.n - bits
    r.consumed = r.consumed + bits
end

local function byte_align(r)
    local over = r.consumed % 8
    if over ~= 0 then
        get(r, 8 - over)
    end
end

--------------------------------------------------------------------------------
-- Huffman
--------------------------------------------------------------------------------

local function length_code(len)
    local idx = 1
    for i = 1, #LEN_BASE do
        if LEN_BASE[i][1] <= len then
            idx = i
        else
            break
        end
    end
    return 256 + idx, len - LEN_BASE[idx][1], LEN_BASE[idx][2]
end

local function distance_code(dist)
    local idx = 1
    for i = 1, #DIST_BASE do
        if DIST_BASE[i][1] <= dist then
            idx = i
        else
            break
        end
    end
    return idx - 1, dist - DIST_BASE[idx][1], DIST_BASE[idx][2]
end

-- Unlimited-depth Huffman. Leaf ids preserve symbol order so equal frequencies
-- always merge the same way.
local function unlimited_lengths(freq)
    local leaves = {}
    for sym, f in pairs(freq) do
        if f > 0 then
            leaves[#leaves + 1] = { sym = sym, freq = f }
        end
    end
    if #leaves == 0 then
        return {}, 0
    end
    if #leaves == 1 then
        return { [leaves[1].sym] = 1 }, 1
    end
    table.sort(leaves, function(a, b)
        if a.freq ~= b.freq then return a.freq < b.freq end
        return a.sym < b.sym
    end)

    local nodes = {}
    for i, leaf in ipairs(leaves) do
        nodes[i] = { freq = leaf.freq, sym = leaf.sym, id = i }
    end
    local seq = #leaves
    while #nodes > 1 do
        table.sort(nodes, function(a, b)
            if a.freq ~= b.freq then return a.freq < b.freq end
            return a.id < b.id
        end)
        local left = table.remove(nodes, 1)
        local right = table.remove(nodes, 1)
        seq = seq + 1
        nodes[#nodes + 1] = {
            freq = left.freq + right.freq,
            left = left,
            right = right,
            id = seq,
        }
    end

    local lengths = {}
    local max_depth = 0
    local function walk(node, depth)
        if node.sym ~= nil then
            local d = depth == 0 and 1 or depth
            lengths[node.sym] = d
            if d > max_depth then max_depth = d end
        else
            walk(node.left, depth + 1)
            walk(node.right, depth + 1)
        end
    end
    walk(nodes[1], 0)
    return lengths, max_depth
end

local function kraft_ok(lengths, max_len)
    local sum = 0
    local limit = 1 << max_len
    for _, len in pairs(lengths) do
        if len < 1 or len > max_len then return false end
        sum = sum + (1 << (max_len - len))
    end
    return sum <= limit
end

-- Dynamic Huffman codes in a deflate block cannot be longer than 15 (literals
-- and distances) or 7 (the code-length alphabet, which is stored in 3 bits).
-- The adjustment is the one in zlib's gen_bitlen: pull over-long leaves back
-- to max_len by lengthening some shorter codes. If that bookkeeping ever fails
-- the Kraft inequality, every used symbol gets length max_len, which always
-- fits (the alphabets here are far smaller than 2^max_len).
local function limit_lengths(freq, max_len)
    local lengths, max_depth = unlimited_lengths(freq)
    if max_depth <= max_len then
        return lengths
    end

    local bl_count = {}
    for i = 0, max_depth do
        bl_count[i] = 0
    end
    local overflow = 0
    for _, len in pairs(lengths) do
        if len > max_len then
            overflow = overflow + 1
        else
            bl_count[len] = bl_count[len] + 1
        end
    end

    local guard = 0
    while overflow > 0 do
        guard = guard + 1
        if guard > 10000 then break end
        local bits = max_len - 1
        while bits > 0 and bl_count[bits] == 0 do
            bits = bits - 1
        end
        if bits == 0 then break end
        bl_count[bits] = bl_count[bits] - 1
        bl_count[bits + 1] = bl_count[bits + 1] + 2
        bl_count[max_len] = bl_count[max_len] - 1
        overflow = overflow - 2
    end

    local syms = {}
    for sym, f in pairs(freq) do
        if f > 0 then syms[#syms + 1] = sym end
    end
    table.sort(syms, function(a, b)
        if freq[a] ~= freq[b] then return freq[a] < freq[b] end
        return a < b
    end)

    local limited = {}
    local bits = max_len
    local failed = overflow > 0
    for _, sym in ipairs(syms) do
        while bits > 0 and (bl_count[bits] or 0) == 0 do
            bits = bits - 1
        end
        if bits == 0 then
            failed = true
            break
        end
        limited[sym] = bits
        bl_count[bits] = bl_count[bits] - 1
    end
    if failed or not kraft_ok(limited, max_len) then
        limited = {}
        for _, sym in ipairs(syms) do
            limited[sym] = max_len
        end
    end
    return limited
end

-- RFC 1951 section 3.2.2. `codes[sym]` is the integer whose high bit is sent first.
local function canonical_codes(lengths)
    local bl_count = {}
    local max_len = 0
    local syms = {}
    for sym, len in pairs(lengths) do
        if len > 0 then
            bl_count[len] = (bl_count[len] or 0) + 1
            if len > max_len then max_len = len end
            syms[#syms + 1] = sym
        end
    end
    table.sort(syms)
    local next_code = {}
    local code = 0
    bl_count[0] = 0
    for nbits = 1, max_len do
        code = (code + (bl_count[nbits - 1] or 0)) << 1
        next_code[nbits] = code
    end
    local codes = {}
    for _, sym in ipairs(syms) do
        local len = lengths[sym]
        codes[sym] = next_code[len]
        next_code[len] = next_code[len] + 1
    end
    return codes
end

-- First stream bit is the low bit of the index. A code of length L occupies
-- every slot whose low L bits are the bit-reversed code, so a peek of
-- `peek_bits` can resolve it without walking a tree.
local function build_decode_table(lengths, peek_bits)
    local codes = canonical_codes(lengths)
    local size = 1 << peek_bits
    local symbol_of = {}
    local length_of = {}
    for sym, len in pairs(lengths) do
        if len > 0 then
            if len > peek_bits then
                error("Deflate code longer than the decoder peek width.")
            end
            local rev = 0
            local code = codes[sym]
            for _ = 1, len do
                rev = (rev << 1) | (code & 1)
                code = code >> 1
            end
            local fill = rev
            local step = 1 << len
            while fill < size do
                symbol_of[fill] = sym
                length_of[fill] = len
                fill = fill + step
            end
        end
    end
    return symbol_of, length_of
end

local function read_symbol(r, symbol_of, length_of, peek_bits)
    local looked = peek(r, peek_bits)
    local sym = symbol_of[looked]
    local len = length_of[looked]
    if sym == nil or len == nil or len == 0 or len > r.n then
        error("Truncated or invalid deflate stream.")
    end
    drop(r, len)
    return sym
end

--------------------------------------------------------------------------------
-- LZ77
--------------------------------------------------------------------------------

local function hash3(s, i)
    local a, b, c = s:byte(i, i + 2)
    return ((a * 31 + b) * 31 + c) & (HASH_SIZE - 1)
end

local function match_length(s, earlier, here, max_len)
    local n = 0
    while n < max_len and s:byte(earlier + n) == s:byte(here + n) do
        n = n + 1
    end
    return n
end

local function find_match(s, i, n, head, prev)
    if i + MIN_MATCH - 1 > n then
        return 0, 0
    end
    local best_len, best_dist = MIN_MATCH - 1, 0
    local max_len = n - i + 1
    if max_len > MAX_MATCH then max_len = MAX_MATCH end
    local p = head[hash3(s, i)] or 0
    local chain = 0
    local limit = i - WINDOW
    if limit < 1 then limit = 1 end
    while p ~= 0 and p >= limit and chain < MAX_CHAIN do
        if s:byte(p) == s:byte(i)
            and s:byte(p + best_len - 1) == s:byte(i + best_len - 1) then
            local len = match_length(s, p, i, max_len)
            if len > best_len then
                best_len = len
                best_dist = i - p
                if best_len == max_len then break end
            end
        end
        chain = chain + 1
        p = prev[p] or 0
    end
    if best_len < MIN_MATCH then
        return 0, 0
    end
    return best_len, best_dist
end

local function insert_at(s, i, n, head, prev)
    if i + MIN_MATCH - 1 > n then return end
    local h = hash3(s, i)
    prev[i] = head[h] or 0
    head[h] = i
end

-- Tokens are { b = byte } for a literal, or { d = distance, n = length } for a copy.
local function lz77(s)
    local n = #s
    local head, prev = {}, {}
    local tokens = {}
    local i = 1
    while i <= n do
        local len, dist = find_match(s, i, n, head, prev)
        if len >= MIN_MATCH and len < LAZY_BELOW and i < n then
            local len2, dist2 = find_match(s, i + 1, n, head, prev)
            if len2 > len then
                tokens[#tokens + 1] = { b = s:byte(i) }
                insert_at(s, i, n, head, prev)
                i = i + 1
                len, dist = len2, dist2
            end
        end
        if len >= MIN_MATCH then
            tokens[#tokens + 1] = { d = dist, n = len }
            local last = i + len - 1
            while i <= last do
                insert_at(s, i, n, head, prev)
                i = i + 1
            end
        else
            tokens[#tokens + 1] = { b = s:byte(i) }
            insert_at(s, i, n, head, prev)
            i = i + 1
        end
    end
    return tokens
end

--------------------------------------------------------------------------------
-- Dynamic block encode
--------------------------------------------------------------------------------

-- Run-length encode a code-length array the way section 3.2.7 describes.
-- `lengths` is keyed from 0. A run never starts with symbol 16; that symbol
-- means "repeat the previous length", and the previous length has to exist.
local function encode_lengths(lengths, count)
    local ops = {}
    local i = 0
    while i < count do
        local len = lengths[i] or 0
        local j = i + 1
        while j < count and (lengths[j] or 0) == len do
            j = j + 1
        end
        local left = j - i
        if len == 0 then
            while left >= 11 do
                local n = math.min(left, 138)
                ops[#ops + 1] = { sym = 18, extra = n - 11, bits = 7 }
                left = left - n
            end
            while left >= 3 do
                local n = math.min(left, 10)
                ops[#ops + 1] = { sym = 17, extra = n - 3, bits = 3 }
                left = left - n
            end
            while left > 0 do
                ops[#ops + 1] = { sym = 0 }
                left = left - 1
            end
        else
            ops[#ops + 1] = { sym = len }
            left = left - 1
            while left >= 3 do
                local n = math.min(left, 6)
                ops[#ops + 1] = { sym = 16, extra = n - 3, bits = 2 }
                left = left - n
            end
            while left > 0 do
                ops[#ops + 1] = { sym = len }
                left = left - 1
            end
        end
        i = j
    end
    return ops
end

local function last_used(lengths, minimum)
    local last = minimum
    for sym, len in pairs(lengths) do
        if len > 0 and sym > last then last = sym end
    end
    return last
end

local function write_dynamic_block(tokens)
    local lit_freq = { [256] = 1 }
    local dist_freq = {}
    for _, tok in ipairs(tokens) do
        if tok.b ~= nil then
            lit_freq[tok.b] = (lit_freq[tok.b] or 0) + 1
        else
            local lsym = length_code(tok.n)
            local dsym = distance_code(tok.d)
            lit_freq[lsym] = (lit_freq[lsym] or 0) + 1
            dist_freq[dsym] = (dist_freq[dsym] or 0) + 1
        end
    end
    -- A dynamic block always carries a distance tree, even when nothing matched.
    if next(dist_freq) == nil then
        dist_freq[0] = 1
    end

    local lit_len = limit_lengths(lit_freq, 15)
    local dist_len = limit_lengths(dist_freq, 15)
    local lit_codes = canonical_codes(lit_len)
    local dist_codes = canonical_codes(dist_len)

    local lit_count = math.max(last_used(lit_len, 256) + 1, 257)
    local dist_count = math.max(last_used(dist_len, 0) + 1, 1)
    if lit_count > 286 then lit_count = 286 end
    if dist_count > 32 then dist_count = 32 end

    local ops = encode_lengths(lit_len, lit_count)
    local dist_ops = encode_lengths(dist_len, dist_count)
    for _, op in ipairs(dist_ops) do
        ops[#ops + 1] = op
    end

    local cl_freq = {}
    for _, op in ipairs(ops) do
        cl_freq[op.sym] = (cl_freq[op.sym] or 0) + 1
    end
    local cl_len = limit_lengths(cl_freq, 7)
    local cl_codes = canonical_codes(cl_len)

    local hclen = 4
    for i = #CL_ORDER, 5, -1 do
        if (cl_len[CL_ORDER[i]] or 0) ~= 0 then
            hclen = i
            break
        end
    end

    local w = writer_new()
    put_lsb(w, 1, 1) -- final block
    put_lsb(w, 2, 2) -- BTYPE = 10, dynamic Huffman
    put_lsb(w, lit_count - 257, 5)
    put_lsb(w, dist_count - 1, 5)
    put_lsb(w, hclen - 4, 4)
    for i = 1, hclen do
        put_lsb(w, cl_len[CL_ORDER[i]] or 0, 3)
    end
    for _, op in ipairs(ops) do
        local len = cl_len[op.sym]
        if len == nil or len == 0 then
            error("Deflate encoder produced a code-length symbol with no code.")
        end
        put_msb(w, cl_codes[op.sym], len)
        if op.bits ~= nil then
            put_lsb(w, op.extra, op.bits)
        end
    end

    local function put_sym(codes, lengths, sym)
        local len = lengths[sym]
        if len == nil or len == 0 then
            error("Deflate encoder produced a symbol with no code.")
        end
        put_msb(w, codes[sym], len)
    end

    for _, tok in ipairs(tokens) do
        if tok.b ~= nil then
            put_sym(lit_codes, lit_len, tok.b)
        else
            local lsym, lextra, lbits = length_code(tok.n)
            local dsym, dextra, dbits = distance_code(tok.d)
            put_sym(lit_codes, lit_len, lsym)
            put_lsb(w, lextra, lbits)
            put_sym(dist_codes, dist_len, dsym)
            put_lsb(w, dextra, dbits)
        end
    end
    put_sym(lit_codes, lit_len, 256)
    return writer_finish(w)
end

--------------------------------------------------------------------------------
-- Inflate
--------------------------------------------------------------------------------

local function append_byte(out, byte)
    if #out >= Deflate.MAX_OUTPUT then
        error("Deflate output exceeded " .. tostring(Deflate.MAX_OUTPUT) .. " bytes.")
    end
    out[#out + 1] = string.char(byte)
end

local function append_copy(out, dist, len)
    if dist < 1 or dist > #out then
        error("Deflate distance out of range.")
    end
    if #out + len > Deflate.MAX_OUTPUT then
        error("Deflate output exceeded " .. tostring(Deflate.MAX_OUTPUT) .. " bytes.")
    end
    -- Byte by byte so a length longer than the distance overlaps itself,
    -- which the format allows (a run of one repeated byte).
    local start = #out - dist + 1
    for k = 0, len - 1 do
        out[#out + 1] = out[start + k]
    end
end

local function inflate_codes(r, lit_sym, lit_n, lit_peek, dist_sym, dist_n, dist_peek, out)
    while true do
        local sym = read_symbol(r, lit_sym, lit_n, lit_peek)
        if sym < 256 then
            append_byte(out, sym)
        elseif sym == 256 then
            return
        else
            local spec = LEN_BASE[sym - 256]
            if spec == nil then
                error("Invalid deflate length code.")
            end
            local len = spec[1] + get(r, spec[2])
            local dsym = read_symbol(r, dist_sym, dist_n, dist_peek)
            local dspec = DIST_BASE[dsym + 1]
            if dspec == nil then
                error("Invalid deflate distance code.")
            end
            append_copy(out, dspec[1] + get(r, dspec[2]), len)
        end
    end
end

local fixed_lit_sym, fixed_lit_n, fixed_dist_sym, fixed_dist_n

local function ensure_fixed_tables()
    if fixed_lit_sym ~= nil then return end
    local lit, dist = {}, {}
    for sym = 0, 287 do
        if sym <= 143 then
            lit[sym] = 8
        elseif sym <= 255 then
            lit[sym] = 9
        elseif sym <= 279 then
            lit[sym] = 7
        else
            lit[sym] = 8
        end
    end
    for sym = 0, 31 do
        dist[sym] = 5
    end
    fixed_lit_sym, fixed_lit_n = build_decode_table(lit, 9)
    fixed_dist_sym, fixed_dist_n = build_decode_table(dist, 5)
end

local function inflate_stored(r, out)
    byte_align(r)
    local len = get(r, 16)
    local nlen = get(r, 16)
    if (nlen ~ len) ~= 0xFFFF then
        error("Corrupt stored deflate block.")
    end
    for _ = 1, len do
        append_byte(out, get(r, 8))
    end
end

local function read_code_lengths(r, cl_sym, cl_n, count)
    local lengths = {}
    local filled = 0
    local prev = 0
    while filled < count do
        local sym = read_symbol(r, cl_sym, cl_n, 7)
        local n
        if sym <= 15 then
            n = 1
            prev = sym
        elseif sym == 16 then
            if filled == 0 then
                error("Deflate length repeat with no previous length.")
            end
            sym = prev
            n = get(r, 2) + 3
        elseif sym == 17 then
            sym = 0
            prev = 0
            n = get(r, 3) + 3
        elseif sym == 18 then
            sym = 0
            prev = 0
            n = get(r, 7) + 11
        else
            error("Invalid deflate code-length symbol.")
        end
        if filled + n > count then
            error("Deflate code-length list overruns its header.")
        end
        for _ = 1, n do
            lengths[filled] = sym
            filled = filled + 1
        end
    end
    return lengths
end

local function inflate_dynamic(r, out)
    local hlit = get(r, 5) + 257
    local hdist = get(r, 5) + 1
    local hclen = get(r, 4) + 4
    if hlit > 286 or hdist > 32 then
        error("Invalid dynamic deflate header.")
    end
    local cl_lengths = {}
    for i = 1, hclen do
        cl_lengths[CL_ORDER[i]] = get(r, 3)
    end
    local cl_sym, cl_n = build_decode_table(cl_lengths, 7)
    local all = read_code_lengths(r, cl_sym, cl_n, hlit + hdist)
    local lit_lengths, dist_lengths = {}, {}
    for i = 0, hlit - 1 do
        lit_lengths[i] = all[i]
    end
    for i = 0, hdist - 1 do
        dist_lengths[i] = all[hlit + i]
    end
    local lit_sym, lit_n = build_decode_table(lit_lengths, 15)
    local dist_sym, dist_n = build_decode_table(dist_lengths, 15)
    inflate_codes(r, lit_sym, lit_n, 15, dist_sym, dist_n, 15, out)
end

local function inflate_to(data)
    local r = reader_new(data)
    local out = {}
    local bfinal = 0
    repeat
        bfinal = get(r, 1)
        local btype = get(r, 2)
        if btype == 0 then
            inflate_stored(r, out)
        elseif btype == 1 then
            ensure_fixed_tables()
            inflate_codes(r, fixed_lit_sym, fixed_lit_n, 9, fixed_dist_sym, fixed_dist_n, 5, out)
        elseif btype == 2 then
            inflate_dynamic(r, out)
        else
            error("Reserved deflate block type.")
        end
    until bfinal == 1
    if r.pos <= #data then
        error("Trailing data after deflate stream.")
    end
    return table.concat(out)
end

--------------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------------

---Compress `data` to one raw deflate block (no zlib or gzip wrapper).
---@param data string
---@return string
function Deflate.compress(data)
    if type(data) ~= "string" then
        error("Deflate.compress expects a string.")
    end
    return write_dynamic_block(lz77(data))
end

---Inflate a raw deflate stream produced by compress(), or by any other encoder
---that writes stored, fixed, or dynamic blocks without a zlib/gzip header.
---@param data string
---@return string
function Deflate.decompress(data)
    if type(data) ~= "string" then
        error("Deflate.decompress expects a string.")
    end
    if data == "" then
        error("Truncated deflate stream.")
    end
    return inflate_to(data)
end

return Deflate
