local t = { a = 1 }
t["b"] = 2
t["a"] = t["a"] + 3
print(t["a"], t.b, t["missing"])

