from collections import defaultdict

with open("input.txt", "r") as file:
    lines = [tuple(int(num) for num in line.strip().split(',')) for line in file.readlines()]

class UF:
    def __init__(self, n):
        self.n = n
        self.comp = [i for i in range(n)]
        self.size = [1] * n
        self.comps = n

    def union(self, a, b):
        para = self.find(a)
        parb = self.find(b)
        
        if para == parb: return
        self.comps -= 1
        if self.size[para] < self.size[parb]:
            self.size[parb] += self.size[para]
            self.comp[para] = parb
        else:
            self.size[para] += self.size[parb]
            self.comp[parb] = para

    def find(self, a):
        root = a
        while self.comp[root] != root: root = self.comp[root]
        while self.comp[a] != root:
            na = self.comp[a]
            self.comp[a] = root
            a = na
        return root

# Part 1
dist = lambda b1, b2: sum((n1 - n2) ** 2 for n1, n2 in zip(b1, b2))
D_to_V = defaultdict(list)
N = len(lines)
for v1 in range(N-1):
    for v2 in range(v1+1, N):
        b1 = lines[v1]
        b2 = lines[v2]
        D = dist(b1, b2)
        D_to_V[D].append((v1, v2))

uf = UF(N)
ct = 0
for k in sorted(D_to_V.keys()):
    for v1, v2 in D_to_V[k]:
        uf.union(v1, v2)
        ct += 1
        if ct == 1000: break
    if ct == 1000: break

sizes = sorted(uf.size, reverse=True)
print(sizes[0] * sizes[1] * sizes[2])

# Part 2
uf = UF(N)
ans = None
for k in sorted(D_to_V.keys()):
    for v1, v2 in D_to_V[k]:
        uf.union(v1, v2)
        if uf.comps == 1:
            ans = lines[v1][0] * lines[v2][0]
            break
    if uf.comps == 1: break

print(ans)
