import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) >= 1, old
open(path, "w").write(s.replace(old, new))
