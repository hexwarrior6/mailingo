#!/usr/bin/env python3
"""把真实邮件的 fixture 脱敏后入库。

真实邮件 fixtures 对 MIME 解析和 HTML 保真的测试价值最大，但里面含真实
邮箱地址与 Message-ID，不能原样提交。这个脚本固化脱敏流程：

    python3 Scripts/anonymize-email.py <原始.eml> <输出.eml>

替换规则：Message-ID → <fixture-msgid-N@example.com>，所有邮箱地址 →
userN@example.com，机构/部门名 → Example 系列。全程按 isoLatin1 逐字节
读写，**不触碰行尾、折行、编码和 multipart 结构** —— 否则 fixture 就失真了。

来源：~/Library/Containers/com.zhuyuhao.Mailingo.MailExtension/Data/Library/Logs/Mailingo/last-message.eml
（appex 会把 Mail 递来的最近一封邮件写在那里）
"""

import re, sys

src, dst = sys.argv[1], sys.argv[2]
raw = open(src, 'rb').read()
# isoLatin1 = 逐字节映射，保证脱敏不破坏字节结构
text = raw.decode('latin-1')

# 1) Message-ID 先处理（否则会被下面的邮箱规则拆坏）
n = [0]
def sub_msgid(m):
    n[0] += 1
    return f"<fixture-msgid-{n[0]}@example.com>"
text = re.sub(r'<[^<>\s]+@[^<>\s]+>', sub_msgid, text)

# 2) 所有邮箱地址
m = [0]
def sub_email(mo):
    m[0] += 1
    return f"user{m[0]}@example.com"
text = re.sub(r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}', sub_email, text)

# 3) 机构/部门名
for a, b in [
    ('ntu.edu.sg', 'example.edu'),
    ('NTU', 'EXAMPLE'),
    ('Nanyang Technological University', 'Example University'),
    ('EEE-Graduate Coursework Programmes', 'Example Coursework Programmes'),
    ('EEE GPU Cluster Admin', 'Example Cluster Admin'),
    ('EEE GPU Cluster', 'Example Cluster'),
    ('EEE', 'EXA'),
]:
    text = text.replace(a, b)

open(dst, 'wb').write(text.encode('latin-1'))
print(f"Message-ID 替换 {n[0]} 处，邮箱替换 {m[0]} 处")
