#!/usr/bin/env python3
# docs-check gate v1 (generated)
#
# 仓层最小闸 —— 三条：B1 指令预算 · I1+I2 索引双向不变量 · L1 仓内死链
# （死链按「编号前缀 → 唯一 basename」解析，改名/搬家会给出建议；ADR-0015）。
#
# **不要手改。** 它由 nan-fedora 的 docs-check skill 生成：
#     docs_check.py <repo> --emit-gate py --emit-out scripts/docs-gate.py
# 落后版本会被 docs_check.py 的 G1 检查报出来。为什么是**生成物**而不是运行时去找
# skill：CI runner 上没有 `~/code`、没有 `~/.claude/skills`，一个「找不到就跳过」的闸
# 等于没有闸（nan-fedora issue 005 的形态）。判据见 nan-fedora ADR-0014。
#
# 全部 51 项检查在家族层跑：`docs_check.py <repo> --strict`。

import os, re, sys
from pathlib import Path

def _find_root():
    """仓根 = 自己所在目录往上第一个带 .git 的。落盘在仓外时退回 cwd 的仓根
    （方便生成后先在别处跑一次冒烟），两条都找不到就报错退出而不是静默量 0 字节。"""
    for start in (Path(__file__).resolve().parent, Path.cwd().resolve()):
        p = start
        while True:
            if (p / ".git").exists():
                return p
            if p == p.parent:
                break
            p = p.parent
    sys.exit("✗ 找不到 git 仓根 —— 这个闸必须放在它要守护的仓里")


ROOT = _find_root()

BUDGET = int(os.environ.get("DSH_INSTRUCTION_BUDGET",
             os.environ.get("INSTRUCTION_BUDGET", "65536")))
ENTRY = ("CLAUDE.md", "AGENTS.md", "CLAUDE.local.md", "AGENTS.local.md")
PLACEHOLDER = re.compile(r"XXXX|NNNN|MMMM|NNN-|<[^>]*>|\{\{|\.\.\.|…")
LINK = re.compile(r"\]\(\s*<?([^)\s<>]+)>?(?:\s+\"[^\"]*\")?\s*\)")


def blank_code(text):
    out = list(text)

    def wipe(a, b):
        for i in range(a, b):
            if out[i] != "\n":
                out[i] = " "
    for m in re.finditer(r"(?ms)^[ \t]{0,3}(`{3,}|~{3,})[^\n]*\n.*?(?:^[ \t]{0,3}\1[ \t]*$|\Z)", text):
        wipe(m.start(), m.end())
    cur = "".join(out)
    for m in re.finditer(r"`+[^`\n]*`+", cur):
        wipe(m.start(), m.end())
    return "".join(out)


def check_budget(fail):
    total = sum(len((ROOT / n).read_bytes()) for n in ENTRY if (ROOT / n).is_file())
    if total > BUDGET:
        fail("B1 指令预算 %d / %d B —— 超 %d。加载侧会静默截断尾部；出路是分流不是抬预算。"
             % (total, BUDGET, total - BUDGET))
    else:
        print("B1 指令预算 ✓ %d / %d B" % (total, BUDGET))


def check_index(fail, sub, pat):
    d = ROOT / sub
    readme = d / "README.md"
    if not d.is_dir() or not readme.is_file():
        return
    files = {p.name for p in d.glob("*.md")
             if re.match(pat, p.name) and p.name not in ("0000-template.md", "template.md")}
    text = blank_code(readme.read_text(encoding="utf-8", errors="replace"))
    linked = set(re.findall(r"\]\((?:\./)?(\d{3,4}-[^)#]*?\.md)[^)]*\)", text))
    nums = {n.split("-")[0] for n in linked} | set(re.findall(r"\]\((\d{3,4})\)", text))
    for line in text.splitlines():
        if line.lstrip().startswith("|"):
            m = re.match(r"\|\s*\[?\s*(\d{3,4})\b", line)
            if m:
                nums.add(m.group(1))
    orphan = sorted(f for f in files if f not in linked and f.split("-")[0] not in nums)
    dead = sorted(n for n in linked if not (d / n).is_file())
    if orphan:
        fail("I1 %s ORPHAN（有文件没索引行）: %s" % (sub, ", ".join(orphan)))
    if dead:
        fail("I2 %s DEAD（索引行指向不存在的文件）: %s" % (sub, ", ".join(dead)))
    if not orphan and not dead:
        print("I1/I2 %s ✓ %d 文件 / %d 索引行 双向不变量成立" % (sub, len(files), len(linked)))


def _resolve(src, target):
    """编号前缀 → 唯一 basename → 编号+搬家。返回 (ok, 建议)。"""
    p = (src.parent / target).resolve()
    if p.exists():
        return True, None
    base = p.name
    m = re.match(r"^(\d{3,4})-", base)
    if m and p.parent.is_dir():
        c = sorted(x for x in p.parent.glob(m.group(1) + "-*") if x.is_file())
        if len(c) == 1:
            return False, os.path.relpath(str(c[0]), str(src.parent))
    docs = ROOT / "docs"
    if docs.is_dir():
        c = [x for x in docs.rglob(base) if x.is_file() and "archive" not in x.parts]
        if len(c) == 1:
            return False, os.path.relpath(str(c[0]), str(src.parent))
        if m:
            c = [x for x in docs.rglob(m.group(1) + "-*")
                 if x.is_file() and x.suffix == ".md" and "archive" not in x.parts]
            if len(c) == 1:
                return False, os.path.relpath(str(c[0]), str(src.parent))
    return False, None


def check_links(fail):
    targets = [ROOT / n for n in ENTRY if (ROOT / n).is_file()]
    if (ROOT / "docs").is_dir():
        targets += sorted((ROOT / "docs").rglob("*.md"))
    broken = []
    for f in targets:
        rel = f.relative_to(ROOT).as_posix()
        if rel.startswith("docs/research/") or rel.startswith("docs/archive/"):
            continue  # 研究/归档是点时快照，引用的东西搬走是历史不是缺陷
        if f.name in ("0000-template.md", "template.md"):
            continue
        for m in LINK.finditer(blank_code(f.read_text(encoding="utf-8", errors="replace"))):
            t = m.group(1).split("#")[0]
            if not t or re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", t) or t.startswith("~"):
                continue
            if PLACEHOLDER.search(t) or "*" in t:
                continue
            try:
                p = (f.parent / t).resolve()
                p.relative_to(ROOT)
            except ValueError:
                continue  # 跨仓：只计数不 resolve
            except OSError:
                pass
            ok, sug = _resolve(f, t)
            if not ok:
                broken.append("%s: %s%s" % (rel, t, "  → 疑似改名/搬家，应为 " + sug if sug else ""))
    if broken:
        fail("L1 仓内死链 %d 条:\n    %s" % (len(broken), "\n    ".join(broken)))
    else:
        print("L1 仓内相对链接 ✓ 无死链")


def run():
    errs = []
    check_budget(errs.append)
    check_index(errs.append, "docs/issues", r"^\d{3,4}-")
    check_index(errs.append, "docs/adr", r"^\d{4}-")
    check_links(errs.append)
    for e in errs:
        print("✗ " + e)
    return errs


def main():
    errs = run()
    print("\n✓ docs gate 通过" if not errs else "\n✗ docs gate 失败 %d 项" % len(errs))
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
