import re
import sys
from collections import defaultdict

ignore_re = re.compile(r"\s*[#;.].*\n|\s*\n|^\w+:.*\n")
mnem_re = re.compile(r"\w+")
mnem_count = defaultdict(int)
for line in sys.stdin:
    if line == "---\n":
        break
    if ignore_re.fullmatch(line):
        continue
    m = mnem_re.search(line)
    if not m:
        continue
    mnem = m[0].removesuffix("_e32").removesuffix("_e64")
    mnem_count[mnem] += 1
for k, v in sorted(mnem_count.items()):
    print(k, v)
