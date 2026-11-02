#!/usr/bin/env python3
"""Generate a category-level benchmark report from a Reflex session markdown log."""
import re, sys, statistics

CAT_MAP = {
    "open_app": "app_control", "quit": "app_control", "open_folder": "app_control",
    "new_item": "app_control",
    "media_control": "media_control",
    "display_control": "system_control", "system_control": "system_control",
    "shortcut": "system_control", "screenshot": "system_control",
    "type_text": "text_input", "dictation": "text_input",
    "web_search": "web_search", "browser_command": "web_search",
    "file_operation": "file_operation", "environment_setup": "workflow",
    "general_query": "no_op",
}

def parse(path):
    text = open(path).read()
    # split entries
    entries = re.split(r"\n## \d+\. ", text)[1:]
    rows = []
    for e in entries:
        t = re.search(r'^(\d{2}:\d{2}:\d{2}\.\d{3})', e)
        time = t.group(1) if t else ""
        tr = re.search(r'— "([^"]*)"', e)
        transcript = tr.group(1) if tr else ""
        tgt = re.search(r'- Target: (\S+)', e)
        target = tgt.group(1) if tgt else ""
        act = re.search(r'- Action: (.*)', e)
        action = act.group(1).strip() if act else ""
        vtd = re.search(r'voice→dispatch (\S+)', e)
        vtdv = vtd.group(1) if vtd else "–"
        execp = re.search(r'Execution: (\S+)', e)
        path_ = execp.group(1) if execp else "finalized"
        # latency numbers
        def num(label):
            m = re.search(rf'{label} (\d+)', e)
            return int(m.group(1)) if m else None
        rows.append({
            "time": time, "transcript": transcript, "target": target,
            "category": CAT_MAP.get(target, "other"),
            "action": action, "execution_path": path_,
            "voice_to_dispatch": None if vtdv == "–" else int(vtdv),
            "decode": num("decode"), "route": num("route"), "dispatch": num("dispatch"),
            "early": "incremental" in path_,
        })
    return rows

def stats(vals):
    if not vals: return "n=0"
    vals = sorted(vals)
    def pct(p):
        idx = max(0, min(len(vals)-1, int(round(p/100*(len(vals)-1)))))
        return vals[idx]
    return f"n={len(vals)} mean={round(sum(vals)/len(vals))} p50={pct(50)} p95={pct(95)}"

def main(path):
    rows = parse(path)
    print(f"# Benchmark report — {path}")
    print(f"Total entries: {len(rows)}")
    early = [r for r in rows if r["early"]]
    fin = [r for r in rows if not r["early"]]
    print(f"Early commits: {len(early)}")
    print(f"Finalized: {len(fin)}")
    noop = [r for r in rows if r["action"].startswith("No-op")]
    failed = [r for r in rows if "failed" in r["action"].lower() or "Execute failed" in r["action"]]
    succ = [r for r in rows if not (r["action"].startswith("No-op") or "failed" in r["action"].lower() or "Execute failed" in r["action"])]
    pct = round(100*len(succ)/len(rows)) if rows else 0
    print(f"Success: {len(succ)}/{len(rows)} ({pct}%)")
    print(f"No-ops: {len(noop)}, Failed: {len(failed)}")
    print()
    cats = {}
    for r in rows:
        cats.setdefault(r["category"], []).append(r)
    print("## By category")
    for cat, rs in sorted(cats.items()):
        vtd = [r["voice_to_dispatch"] for r in rs if r["voice_to_dispatch"] is not None]
        print(f"- {cat}: {stats(vtd)} | success={sum(1 for r in rs if not (r['action'].startswith('No-op') or 'failed' in r['action'].lower()))}/{len(rs)}")
    print()
    print("## Incremental vs finalized")
    for label, subset in [("incremental", early), ("finalized", fin)]:
        vtd = [r["voice_to_dispatch"] for r in subset if r["voice_to_dispatch"] is not None]
        print(f"- {label}: {stats(vtd)}")

if __name__ == "__main__":
    main(sys.argv[1])
