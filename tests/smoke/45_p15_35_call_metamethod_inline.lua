-- P15.35 regression: __call metamethod through OP_CALL hot path.
-- Verifies that the in-place stack shift correctly prepends the callee
-- as argument 0 when a non-callable value is called.

-- Single __call resolution
local t = setmetatable({}, { __call = function(self, x)
    return x + 1
end})
assert(t(41) == 42, "single __call through OP_CALL")

-- __call with multiple args
local t2 = setmetatable({}, { __call = function(self, a, b, c)
    return a + b + c
end})
assert(t2(10, 20, 30) == 60, "__call with 3 args")

-- Two sequential __call resolutions: outer's __call delegates to a callable
-- inner table. This exercises __call resolution twice (once for outer, once
-- for inner) in two separate OP_CALL invocations — not a PUC CIST_CCMT chain.
local inner = setmetatable({}, { __call = function(self, x)
    return x * 2
end})
local outer = setmetatable({}, { __call = function(self, x)
    return inner(x)  -- inner is itself callable via __call
end})
assert(outer(21) == 42, "two sequential __call resolutions")

-- __call in tail position (OP_TAILCALL)
local function tail_call(v)
    return v(100)  -- tail call on a callable table
end
assert(tail_call(t) == 101, "__call through OP_TAILCALL")

-- __call in for-in iterator (OP_TFORCALL)
local function iter_factory(arr)
    local i = 0
    return setmetatable({}, { __call = function(self, state, ctrl)
        i = i + 1
        if i <= #arr then
            return i, arr[i]
        end
    end}), arr, 0
end
local sum = 0
for idx, val in iter_factory({1, 2, 3, 4, 5}) do
    sum = sum + val
end
assert(sum == 15, "__call through OP_TFORCALL iterator")

-- Builtin called normally (fast path, no __call)
assert(type(42) == "number", "builtin fast path still works")
assert(tostring(42) == "42", "builtin with args still works")

print("P15.35 __call inline regression: OK")
