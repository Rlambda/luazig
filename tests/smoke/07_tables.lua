local x = {a = 1, [2] = 3, 4}
x[1] = x[1] + x.a
x[3] = 10
print(x.a, x[2], x[1], x[3])

