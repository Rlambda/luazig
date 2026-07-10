local ok, msg = xpcall(error, error)
print(ok, msg == "error in error handling")

local function loop()
  return 1 + loop()
end

local outer_ok, outer_msg = xpcall(loop, function(err)
  print(type(err) == "string" and err:find("stack overflow", 1, true) ~= nil)

  local inner_ok, inner_msg = pcall(loop)
  print(inner_ok, type(inner_msg) == "string" and
      inner_msg:find("error handling", 1, true) ~= nil)

  return 15
end)

print(outer_ok, outer_msg)
