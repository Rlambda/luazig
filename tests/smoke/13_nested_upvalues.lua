local function outer()
  local x = 1
  local function mid()
    local function inner()
      x = x + 10
      return x
    end
    return inner
  end
  return mid()
end

local f = outer()
print(f(), f())

