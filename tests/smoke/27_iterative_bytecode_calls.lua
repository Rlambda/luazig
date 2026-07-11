local function descend(n)
  if n == 0 then
    return 123
  end
  local result = descend(n - 1)
  return result
end

print(descend(350))
