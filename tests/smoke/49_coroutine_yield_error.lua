-- coroutine.yield outside a coroutine — error format must match PUC.
-- PUC's luaG_runerror skips source location when current function is a C
-- function (coroutine.yield is C), so the error message has no file:line prefix.
local ok, err = pcall(coroutine.yield)
print(ok)
print(err)
