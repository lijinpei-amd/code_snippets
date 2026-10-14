#!/usr/bin/env python3
"""Estimate Claude Code cost per session and per subagent from local transcripts.

Reads ~/.claude/projects/<project>/<session>.jsonl (main thread) and
<session>/**/agent-*.jsonl (+ .meta.json) for subagents. Costs use Anthropic
list prices; a gateway may bill differently.
"""

import argparse
import collections
import datetime
import json
import pathlib
import re

# model prefix -> (input, output, cache_read) in $ per 1M tokens.
# Cache writes: 5m = 1.25x input, 1h = 2x input. Longest prefix wins.
PRICES = {
    "claude-fable-5-1": (10, 50, 0.25),
    "claude-mythos-5-1": (10, 50, 0.25),
    "claude-fable-5": (10, 50, 1.00),
    "claude-mythos-5": (10, 50, 1.00),
    "claude-opus-5-5": (4, 20, 0.20),
    "claude-opus-5": (5, 25, 0.50),
    "claude-opus-4-8": (5, 25, 0.50),
    "claude-opus-4-7": (5, 25, 0.50),
    "claude-opus-4-6": (5, 25, 0.50),
    "claude-opus-4-5": (5, 25, 0.50),
    "claude-opus-4": (15, 75, 1.50),
    "claude-sonnet-5-5": (2, 10, 0.10),
    "claude-sonnet-5": (2, 10, 0.20),
    "claude-sonnet-4": (3, 15, 0.30),
    "claude-haiku-5-5": (0.10, 0.50, 0.01),  # <=100K-token prompt tier
    "claude-haiku-4-5": (1, 5, 0.10),
    "claude-3-5-haiku": (0.80, 4, 0.08),
}

unknown_models = set()


def price_for(model):
    model = re.sub(r"\[.*\]$", "", model)
    for prefix in sorted(PRICES, key=len, reverse=True):
        if model.startswith(prefix):
            return PRICES[prefix]
    unknown_models.add(model)
    return None


class Usage:
    def __init__(self):
        self.cost = 0.0
        self.input = self.output = self.cache_read = self.cache_write = 0
        self.models = collections.Counter()

    def add(self, other):
        self.cost += other.cost
        self.input += other.input
        self.output += other.output
        self.cache_read += other.cache_read
        self.cache_write += other.cache_write
        self.models.update(other.models)


def read_transcript(path):
    """Returns (Usage, first_timestamp, first_user_text) for one jsonl file."""
    # Streaming writes several entries per message id; keep the last one.
    by_id = {}
    first_ts = None
    first_text = ""
    with open(path, errors="replace") as f:
        for line in f:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if first_ts is None and entry.get("timestamp"):
                first_ts = entry["timestamp"]
            msg = entry.get("message")
            if not isinstance(msg, dict):
                continue
            if not first_text and entry.get("type") == "user":
                content = msg.get("content")
                if isinstance(content, str):
                    first_text = content
                elif isinstance(content, list):
                    first_text = next(
                        (b.get("text", "") for b in content
                         if isinstance(b, dict) and b.get("type") == "text"),
                        "",
                    )
            if "usage" in msg and msg.get("model") not in (None, "<synthetic>"):
                by_id[msg.get("id") or id(entry)] = (msg["model"], msg["usage"])

    total = Usage()
    for model, u in by_id.values():
        cw = u.get("cache_creation") or {}
        cw_5m = cw.get("ephemeral_5m_input_tokens", 0)
        cw_1h = cw.get("ephemeral_1h_input_tokens", 0)
        if not cw:
            cw_5m = u.get("cache_creation_input_tokens", 0)
        inp = u.get("input_tokens", 0)
        out = u.get("output_tokens", 0)
        cr = u.get("cache_read_input_tokens", 0)
        p = price_for(model)
        if p:
            p_in, p_out, p_cr = p
            total.cost += (inp * p_in + out * p_out + cr * p_cr
                           + cw_5m * p_in * 1.25 + cw_1h * p_in * 2) / 1e6
        total.input += inp
        total.output += out
        total.cache_read += cr
        total.cache_write += cw_5m + cw_1h
        total.models[re.sub(r"\[.*\]$", "", model)] += 1
    return total, first_ts, first_text


def short(text, n):
    text = " ".join(text.split())
    return text if len(text) <= n else text[: n - 1] + "…"


def fmt_tokens(n):
    return f"{n / 1e6:.1f}M" if n >= 1e6 else f"{n / 1e3:.0f}K"


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--days", type=float, default=7, help="look back N days (default 7)")
    ap.add_argument("--project", default="", help="substring filter on project dir name")
    ap.add_argument("--top", type=int, default=15, help="rows per table (default 15)")
    ap.add_argument("--root", default=str(pathlib.Path.home() / ".claude/projects"))
    args = ap.parse_args()

    cutoff = datetime.datetime.now().timestamp() - args.days * 86400
    sessions = []  # (total_cost, main_usage, sub_usage, ts, project, sid, prompt)
    subagents = []  # (usage, ts, project, sid, agent_type, desc)
    by_type = collections.defaultdict(Usage)

    for proj in pathlib.Path(args.root).iterdir():
        if not proj.is_dir() or args.project not in proj.name:
            continue
        proj_name = proj.name.replace("-mnt-nvme2-jinpli-workspace-home-jinpli", "~")
        for main_file in proj.glob("*.jsonl"):
            sid = main_file.stem
            sub_dir = proj / sid
            files = [main_file] + list(sub_dir.rglob("agent-*.jsonl"))
            if max(f.stat().st_mtime for f in files) < cutoff:
                continue
            main_u, ts, prompt = read_transcript(main_file)
            sub_total = Usage()
            for sf in files[1:]:
                u, sts, _ = read_transcript(sf)
                meta_file = sf.with_suffix(".meta.json")
                meta = json.loads(meta_file.read_text()) if meta_file.exists() else {}
                agent_type = meta.get("agentType", "?")
                subagents.append((u, sts or ts, proj_name, sid, agent_type,
                                  meta.get("description", "")))
                by_type[agent_type].add(u)
                sub_total.add(u)
            sessions.append((main_u.cost + sub_total.cost, main_u, sub_total,
                             ts, proj_name, sid, prompt))

    grand = sum(s[0] for s in sessions)
    print(f"Last {args.days:g} days: {len(sessions)} sessions, "
          f"{len(subagents)} subagents, est. ${grand:,.2f} at list price\n")

    print(f"== Top sessions by cost")
    print(f"{'$total':>8} {'$main':>8} {'$subs':>8} {'out':>6}  {'date':<10} {'session':<8} project / first prompt")
    for cost, mu, su, ts, proj, sid, prompt in sorted(sessions, key=lambda s: -s[0])[: args.top]:
        print(f"{cost:8.2f} {mu.cost:8.2f} {su.cost:8.2f} {fmt_tokens(mu.output + su.output):>6}  "
              f"{(ts or '')[:10]:<10} {sid[:8]:<8} {short(proj, 40)} / {short(prompt, 50)}")

    print(f"\n== Top subagent runs by cost")
    print(f"{'$cost':>8} {'out':>6} {'cacheR':>7}  {'date':<10} {'session':<8} {'type':<18} model / description")
    for u, ts, proj, sid, atype, desc in sorted(subagents, key=lambda s: -s[0].cost)[: args.top]:
        model = ",".join(m.replace("claude-", "") for m in u.models)
        print(f"{u.cost:8.2f} {fmt_tokens(u.output):>6} {fmt_tokens(u.cache_read):>7}  "
              f"{(ts or '')[:10]:<10} {sid[:8]:<8} {short(atype, 18):<18} {model} / {short(desc, 50)}")

    print(f"\n== Subagent cost by type")
    print(f"{'$cost':>9} {'runs':>5} {'$/run':>7}  type")
    counts = collections.Counter(s[4] for s in subagents)
    for atype, u in sorted(by_type.items(), key=lambda kv: -kv[1].cost):
        print(f"{u.cost:9.2f} {counts[atype]:5d} {u.cost / counts[atype]:7.2f}  {atype}")

    if unknown_models:
        print(f"\nNo price for (counted as $0): {', '.join(sorted(unknown_models))}")


if __name__ == "__main__":
    main()
