-- 75_pc_cursor.lua — P16.35 Cut 1 parity gate: dispatch PC as a pointer
-- cursor (PUC `savedpc` ownership model). Every probe attacks an invariant
-- the cursor conversion must preserve: MMBIN skip semantics (previous
-- instruction read), condjump follower reads, EXTRAARG follower reads,
-- backward jumps, heap-PC publication at every park (errors, hooks, yields,
-- GC), and cursor restore on frame re-entry after yield/resume.

-- 1. sequential arithmetic: ADDI + MMBIN(skip) chains (previous-instruction
--    reads on the fallback path are NOT taken; the skip advance is).
local s = 0
for i = 1, 10 do s = s + i end
print("1", s)

-- 2. MMBIN fallback: metamethod arith (MMBIN reads the PREVIOUS instruction
--    to recover the operand after the fast path failed).
local function num(v)
    if type(v) == "table" then return v.n end
    return v
end
local mt = { __add = function(a, b) return num(a) + num(b) end }
local x = setmetatable({ n = 3 }, mt)
local y = setmetatable({ n = 4 }, mt)
print("2", x + y, y + x, x + 10, 10 + x)

-- 3. condjump taken and skipped (follower JMP read + forward jump).
local t = 0
for i = 1, 6 do
    if i % 2 == 0 then t = t + i else t = t - i end
end
print("3", t)

-- 4. EXTRAARG followers: a 300-element constructor crosses the 255 limit, so
--    NEWTABLE and SETLIST both carry EXTRAARG (next-instruction reads).
local big = {}
for i = 1, 300 do big[i] = i end
local packed = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
    11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
    21, 22, 23, 24, 25, 26, 27, 28, 29, 30,
    31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
    41, 42, 43, 44, 45, 46, 47, 48, 49, 50,
    51, 52, 53, 54, 55, 56, 57, 58, 59, 60,
    61, 62, 63, 64, 65, 66, 67, 68, 69, 70,
    71, 72, 73, 74, 75, 76, 77, 78, 79, 80,
    81, 82, 83, 84, 85, 86, 87, 88, 89, 90,
    91, 92, 93, 94, 95, 96, 97, 98, 99, 100,
    101, 102, 103, 104, 105, 106, 107, 108, 109, 110,
    111, 112, 113, 114, 115, 116, 117, 118, 119, 120,
    121, 122, 123, 124, 125, 126, 127, 128, 129, 130,
    131, 132, 133, 134, 135, 136, 137, 138, 139, 140,
    141, 142, 143, 144, 145, 146, 147, 148, 149, 150,
    151, 152, 153, 154, 155, 156, 157, 158, 159, 160,
    161, 162, 163, 164, 165, 166, 167, 168, 169, 170,
    171, 172, 173, 174, 175, 176, 177, 178, 179, 180,
    181, 182, 183, 184, 185, 186, 187, 188, 189, 190,
    191, 192, 193, 194, 195, 196, 197, 198, 199, 200,
    201, 202, 203, 204, 205, 206, 207, 208, 209, 210,
    211, 212, 213, 214, 215, 216, 217, 218, 219, 220,
    221, 222, 223, 224, 225, 226, 227, 228, 229, 230,
    231, 232, 233, 234, 235, 236, 237, 238, 239, 240,
    241, 242, 243, 244, 245, 246, 247, 248, 249, 250,
    251, 252, 253, 254, 255, 256, 257, 258, 259, 260,
    261, 262, 263, 264, 265, 266, 267, 268, 269, 270,
    271, 272, 273, 274, 275, 276, 277, 278, 279, 280,
    281, 282, 283, 284, 285, 286, 287, 288, 289, 290,
    291, 292, 293, 294, 295, 296, 297, 298, 299, 300 }
print("4", #packed, packed[1], packed[256], packed[300], #big, big[300])

-- 5. backward FOR loop (negative-step FORPREP/FORLOOP backward jump).
local d = 0
for i = 10, 1, -2 do d = d + i end
print("5", d)

-- 6. exact error line: the runtime error must report the line of the failing
--    operation (heap-PC publication on the error path).
local ok6, err6 = pcall(function()
    local v6
    return v6 + 1 -- exact failing line for the error-path pc publication
end)
print("6", ok6, err6)

-- 7. hook line visibility: line events must map through the same pc the
--    dispatch cursor holds (hook park publishes, hook return restores).
local lines7 = {}
debug.sethook(function(ev, line) lines7[#lines7 + 1] = line end, "l")
local function f7()
    local a = 1
    local b = 2
    local c = a + b
    return c
end
f7()
debug.sethook()
print("7", #lines7, table.concat(lines7, ","))

-- 8. yield/resume replay mid-loop: the coroutine parks with the cursor
--    mid-loop and must continue the exact next iteration after resume.
local co8 = coroutine.create(function()
    local acc = 0
    for i = 1, 4 do
        acc = acc + i
        coroutine.yield(acc)
    end
    return acc
end)
local r8 = {}
for k = 1, 4 do
    local ok, v = coroutine.resume(co8)
    r8[k] = v
end
local ok8, fin8 = coroutine.resume(co8)
print("8", table.concat(r8, ","), ok8, fin8, coroutine.status(co8))

-- 9. parked-frame GC: a suspended coroutine's frame is parked (pc published)
--    while GC scans it; live locals must survive collection and the resumed
--    loop must continue from the parked pc.
local co9 = coroutine.create(function()
    local keep = { tag = "live" }
    local n = 0
    for i = 1, 100 do
        n = n + #tostring(i)
        if i == 50 then coroutine.yield(keep, n) end
    end
    return keep, n
end)
local ok9a, keep9, n9 = coroutine.resume(co9)
collectgarbage()
collectgarbage()
local ok9b, keep9b, n9b = coroutine.resume(co9)
print("9", ok9a, keep9.tag, n9, ok9b, keep9b.tag, keep9 == keep9b, n9b,
    coroutine.status(co9))

print("pc-cursor-ok")
