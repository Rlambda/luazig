-- Hidden for-loop state must be represented by Proto LocVar metadata rather
-- than inferred from the shape of a particular runtime iterator value.

local function collect(level)
  local entries = {}
  for i = 1, 32 do
    local name, value = debug.getlocal(level + 1, i)
    if name == nil then break end
    entries[#entries + 1] = {name = name, value = value}
  end
  return entries
end

local function filtered(entries, wanted)
  local out = {}
  for i = 1, #entries do
    if entries[i].name == wanted then
      out[#out + 1] = entries[i].value
    end
  end
  return out
end

local function has_name(entries, wanted)
  for i = 1, #entries do
    if entries[i].name == wanted then return true end
  end
  return false
end

local function check_generic()
  local close_value = setmetatable({}, {__close = function () end})
  local state_values, saw_loop_var
  local function iterator()
    local entries = collect(2)  -- iterator -> enclosing loop function
    state_values = filtered(entries, "(for state)")
    saw_loop_var = has_name(entries, "item")
    return nil
  end

  for item in iterator, "state-value", nil, close_value do end
  assert(#state_values == 3)
  assert(state_values[1] == iterator)
  assert(state_values[2] == "state-value")
  assert(state_values[3] == close_value)
  assert(not saw_loop_var)  -- not active during the initial iterator call
end

local function check_numeric()
  local state_values, saw_loop_var
  for i = 1, 1 do
    local entries = collect(1)
    state_values = filtered(entries, "(for state)")
    saw_loop_var = has_name(entries, "i")
    assert(i == 1)
  end
  assert(#state_values == 2)
  assert(saw_loop_var)
end

check_generic()
check_numeric()
print("for-loop-locvars-ok")
