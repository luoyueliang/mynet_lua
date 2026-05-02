import base64, re

with open("/tmp/gfwlist.txt") as f:
    text = f.read()
decoded = base64.b64decode(text).decode("utf-8", errors="ignore")

domains = set()
for line in decoded.split("\n"):
    line = line.strip()
    if not line or line[0] in ("!", "@", "["):
        continue
    line = line.lstrip("||").lstrip("|").lstrip(".")
    m = re.match(r"([a-zA-Z0-9][-a-zA-Z0-9]*\.)+[a-zA-Z]{2,}", line)
    if m:
        d = m.group(0).lower()
        if d.endswith(".cn") or d.endswith(".com.cn"):
            continue
        # 提取所有层级的域名
        parts = d.split(".")
        for i in range(len(parts) - 1):
            sub = ".".join(parts[i:])
            if len(sub.split(".")) >= 2:
                domains.add(sub)

with open("/etc/dnsmasq.d/gfwlist.conf", "w") as f:
    for d in sorted(domains):
        f.write(f"server=/{d}/10.182.236.180\n")

print(f"{len(domains)} domains")
