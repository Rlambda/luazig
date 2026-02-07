global <const> *

local version = "Lua 5.5"
if _VERSION ~= version then
  error("unexpected version: " .. tostring(_VERSION))
end

