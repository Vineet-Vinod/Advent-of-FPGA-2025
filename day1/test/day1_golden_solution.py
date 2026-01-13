with open("input.txt", "r") as file:
    lines = [line.strip() for line in file.readlines()]

ans = 0
st = 50
for i, line in enumerate(lines, 1):
    L = line[0]
    mv = int(line[1:])
    if L == 'L':
        st = (st - mv) % 100
    else:
        st = (st + mv) % 100
    if st == 0:
        ans += 1
print(ans)

# Part 2
ans = 0
st = 50
for i, line in enumerate(lines, 1):
    L = line[0]
    mv = int(line[1:])
    ans += mv // 100
    mv %= 100
    if L == 'L':
        nst = (st - mv) % 100
    else:
        nst = (st + mv) % 100
    if nst == 0 or (L == 'L' and st and nst > st) or (L == 'R' and nst < st):
        ans += 1
    st = nst
print(ans)
