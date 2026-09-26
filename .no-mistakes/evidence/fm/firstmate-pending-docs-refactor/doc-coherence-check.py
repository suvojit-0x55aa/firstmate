"""Check AGENTS.md and the extracted docs for dangling path refs, broken anchors, and bad section refs."""
import re, sys, subprocess
from pathlib import Path
root = Path(sys.argv[1])
files = ["AGENTS.md","docs/state-layout.md","docs/captain-communication.md","docs/no-mistakes-validation.md",
         "docs/session-start-digest.md","docs/validation-invalidation-recovery.md","docs/configuration.md",
         ".agents/skills/quota-array-dispatch/SKILL.md"]
def slug(h):
    s = h.strip().lower()
    s = re.sub(r"[^\w\- ]", "", s)
    return s.replace(" ", "-")
def anchors(p):
    out=set(); counts={}
    infence=False
    for line in p.read_text().splitlines():
        if line.startswith("```"): infence = not infence; continue
        m = re.match(r"^#{1,6}\s+(.*)", line)
        if m and not infence:
            s = slug(m.group(1)); n = counts.get(s,0); counts[s]=n+1
            out.add(s if n==0 else f"{s}-{n}")
    return out
errs=[]; checked=0
tracked=set(subprocess.run(["git","-C",str(root),"ls-files"],capture_output=True,text=True).stdout.split())
for f in files:
    p=root/f
    if not p.exists(): errs.append(f"file missing: {f}"); continue
    text=p.read_text()
    for m in re.finditer(r"\]\(([^)\s]+)\)", text):
        tgt=m.group(1)
        if re.match(r"^[a-z]+:", tgt): continue
        path,_,frag=tgt.partition("#")
        dest=(p.parent/path).resolve() if path else p.resolve()
        checked+=1
        if not dest.exists(): errs.append(f"{f}: link target missing: {tgt}"); continue
        if frag and dest.suffix==".md" and frag not in anchors(dest):
            errs.append(f"{f}: anchor missing: {tgt}")
    for m in re.finditer(r"(?<![\w/.])((?:docs|bin|\.agents/skills)/[A-Za-z0-9_./-]*[A-Za-z0-9_])", text):
        ref=m.group(1).rstrip("/.")
        if re.match(r"[-_./]*[<{*]", text[m.end():]): continue
        if "<" in ref or "*" in ref: continue
        checked+=1
        if not ((root/ref).exists()): errs.append(f"{f}: backticked path missing: {ref}")
    if f=="AGENTS.md":
        for m in re.finditer(r"[Ss]ections? (\d+)", text):
            checked+=1
            if not 1<=int(m.group(1))<=14: errs.append(f"AGENTS.md: section ref out of range: {m.group(0)}")
for d in files[1:6]:
    checked+=1
    if d not in tracked: errs.append(f"new doc not tracked: {d}")
    if d not in (root/"AGENTS.md").read_text() and d!="docs/configuration.md":
        errs.append(f"new doc not referenced from AGENTS.md: {d}")
print(f"checked {checked} references across {len(files)} files")
for e in errs: print("FAIL", e)
print("RESULT:", "ok" if not errs else f"{len(errs)} problem(s)")
sys.exit(1 if errs else 0)
