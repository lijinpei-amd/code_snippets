#!/usr/bin/env python3
"""Count skill invocations and attributed tokens across Claude Code, Codex and Pi sessions.

Invocation detection:
  claude  Skill tool calls, /skill slash commands and forked-skill launches.
  codex   shell/exec tool calls that read a skill file, plus $skill mentions.
  pi      read/bash tool calls on a skill file, plus /skill:<name> expansions.
  A file read counts only when the tool output shows the skill's frontmatter
  name, or a read command (cat, sed, head, ...) succeeded on it, so ls/cp/stat
  and failed reads are ignored.

Token attribution: every model call after a skill loads is charged to it until
the next user prompt (typed or queued; background-task notifications don't
count) or the next skill load. Skills loaded together share the tokens equally.
Repeat loads of one skill within a user turn count once. A forked Claude skill's
own transcript is charged to that skill; other subagent sessions count on their
own. INPUT is uncached input plus cache writes; CACHED is cache reads.

Skill names: rows use the bare skill name, so superpowers:brainstorming (Claude),
brainstorming (Pi) and a Codex read of .../skills/brainstorming/SKILL.md are one
row. Claude Code built-in skills are named claude-code:<name> to keep them apart
from same-named third-party skills. --native-names shows each harness's names.

Unused skills (--include-unused) come from the skill list each harness offers
the model at session start. LAST OFFERED is the newest session that offered the
skill; an old date usually means it has since been removed or renamed.

Snapshots keep per-session results, so data from several machines (or several
scans of one machine) merges without double counting: each session is keyed by
its UUID-bearing file name and the most recent scan of it wins.

Examples:
  skill_usage.py                                   # scan this machine, print table
  skill_usage.py --save a.json                     # scan and save a snapshot
  skill_usage.py a.json b.json --by-host           # merge snapshots, print table
  skill_usage.py a.json --scan --save all.json     # merge a.json with this machine
  skill_usage.py --include-unused                  # also list offered skills with 0 calls

Compressed Codex sessions (*.jsonl.zst) need the `zstandard` module or the `zstd`
binary, e.g. `uv run --with zstandard python skill_usage.py`.
"""

import argparse
import glob
import io
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor
from datetime import datetime, timezone

SNAPSHOT_FORMAT = "skill-usage/2"
READABLE_FORMATS = {"skill-usage/1", SNAPSHOT_FORMAT}
HOME = os.path.expanduser("~")
CODEX_HOME = os.environ.get("CODEX_HOME", f"{HOME}/.codex")
BUILTIN_PREFIX = "claude-code:"
BASE_DIR_PREFIX = "Base directory for this skill: "

PROMPT = ("prompt",)

CMD_NAME_RE = re.compile(r"<command-name>/?([^<\s]+)</command-name>")
FORKED_LAUNCH_RE = re.compile(r"<forked-skill-launch>(\{.*?\})</forked-skill-launch>", re.S)
CLAUDE_LISTED_RE = re.compile(r"^- ([\w.@+-]+(?::[\w.@+-]+)*): ", re.M)
CODEX_ROOT_RE = re.compile(r"^- `(r\d+)` = `([^`]+)`", re.M)
CODEX_LISTED_RE = re.compile(r"^- ([\w.@+-]+(?::[\w.@+-]+)*): .*\(file: ([^)\s]+)\)\s*$", re.M)
CODEX_SKILL_BLOCK_RE = re.compile(r"<skill>\s*<name>([^<]+)</name>\s*<path>([^<]+)</path>")
PI_LISTED_RE = re.compile(r"<skill>\s*<name>([^<]+)</name>[\s\S]*?<location>([^<]+)</location>")
PI_SKILL_BLOCK_RE = re.compile(r'<skill name="([^"]+)" location="([^"]+)"')
PATCH_HEADER_RE = re.compile(r"\*\*\* (?:Add|Update|Delete) File: $")
READ_CMD_RE = re.compile(
    r"""^[\s{(\[]*(?:["']?(?:cmd|command)["']?\s*:\s*)?["'`\[]*\s*"""
    r"""(?:(?:sudo|command|env|time|nice)\s+|\w+=\S*\s+)*"""
    r"""(?:cat|bat|batcat|head|tail|sed|awk|nl|less|more|view|tac|Get-Content)\b"""
)
STDOUT_REDIRECT_RE = re.compile(r"(?<![0-9&>])>(?!&)|&>")
UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
SEGMENT_BREAKS = ("\n", ";", "&", "|", "`", "(", "\\n")
PATH_CHARS = frozenset("._~@+$/{}-")
CODEX_SHELL_TOOLS = {"exec", "shell", "exec_command", "local_shell", "shell_command", "container.exec"}
FAILED_OUTPUT_PREFIXES = ("aborted by user", "exec_command failed")


class ZstdUnavailable(Exception):
    pass


def iter_records(path):
    """Yields the JSON objects of a .jsonl or .jsonl.zst file.

    Lines are split on b"\\n" only; str.splitlines() would also split on the
    U+2028/U+2029 that Claude Code writes raw inside JSON strings.
    """
    for raw in iter_lines(path):
        try:
            rec = json.loads(raw)
        except ValueError:
            continue
        if isinstance(rec, dict):
            yield rec


def iter_lines(path):
    if not path.endswith(".zst"):
        with open(path, "rb") as f:
            yield from f
        return
    try:
        import zstandard  # pyright: ignore[reportMissingImports]
    except ImportError:
        zstandard = None
    if zstandard:
        with open(path, "rb") as f:
            yield from io.BufferedReader(zstandard.ZstdDecompressor().stream_reader(f))
    elif shutil.which("zstd"):
        with subprocess.Popen(["zstd", "-dcq", path], stdout=subprocess.PIPE) as proc:
            assert proc.stdout is not None
            yield from proc.stdout
    else:
        raise ZstdUnavailable(path)


def as_dict(x):
    return x if isinstance(x, dict) else {}


def content_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(c.get("text", "") for c in content if isinstance(c, dict) and isinstance(c.get("text"), str))
    return ""


def strings_in(obj):
    """All string leaves of a JSON value, joined by newlines."""
    if isinstance(obj, str):
        return obj
    if isinstance(obj, dict):
        return "\n".join(strings_in(v) for v in obj.values())
    if isinstance(obj, list):
        return "\n".join(strings_in(v) for v in obj)
    return ""


def canonical(name):
    """Bare skill name shared by all harnesses; built-in and memory skills keep their prefix."""
    if name.startswith((BUILTIN_PREFIX, "memory:")):
        return name
    return name.rsplit(":", 1)[-1]


def normalize_path(path):
    for var, value in (("${HOME}", HOME), ("$HOME", HOME), ("${CODEX_HOME}", CODEX_HOME), ("$CODEX_HOME", CODEX_HOME)):
        if path.startswith(var + "/"):
            path = value + path[len(var) :]
    return os.path.normpath(os.path.expanduser(path))


def skill_from_path(path):
    """Maps a skill file path to a name like ``plugin:skill``, or None if it names no skill."""
    parts = [p for p in path.split("/") if p]
    if parts and parts[-1] == "SKILL.md":
        parts = parts[:-1]
    if not parts or any(p in (".", "..") for p in parts) or re.search(r"[*?{}$]", parts[-1]):
        return None
    name = parts[-1]
    i = len(parts) - 1 - parts[::-1].index("skills") if "skills" in parts else -1
    if i <= 0:
        return name
    for j in range(i - 1):
        if parts[j] == "plugins" and parts[j + 1] == "cache" and j + 3 < i:
            return f"{parts[j + 3]}:{name}"  # plugins/cache/<market>/<plugin>/<ver>/skills/<name>
    parent = parts[i - 1]
    if parent == "memories":
        return f"memory:{name}"
    if "git" in parts[:i] and parent != name:
        return f"{parent}:{name}"  # git-installed package: <repo>/skills/<name>
    return name


def name_for(path, catalog):
    """Names a skill file, preferring the name the harness listed it under."""
    if any(p in (".", "..") for p in path.split("/")):
        return None
    norm = normalize_path(path)
    if norm in catalog:
        return catalog[norm]
    tail = "/" + "/".join(norm.split("/")[-2:])  # <skill dir>/SKILL.md
    hits = {n for p, n in catalog.items() if p.endswith(tail)}
    return hits.pop() if len(hits) == 1 else skill_from_path(norm)


def skill_md_paths(text):
    """Yields (start, skill dir) for each .../SKILL.md path in text, in linear time."""
    i = text.find("/SKILL.md")
    while i != -1:
        after = text[i + 9 : i + 11]
        if not (after[:1].isalnum() or after[:1] in "_-" or (after[:1] == "." and after[1:2].isalnum())):
            j = i
            while j > 0 and (text[j - 1].isalnum() or text[j - 1] in PATH_CHARS):
                j -= 1
            if j > 0 and text[j - 1] == "\\" and text[j : j + 1] in ("n", "t"):
                j += 1  # JSON/JS-escaped "\n" right before the path
            if j < i:
                yield j, text[j:i]
        i = text.find("/SKILL.md", i + 9)


def segment_bounds(text, start):
    """Start and end of the shell command segment around text[start]."""
    begins = [i + len(b) for b in SEGMENT_BREAKS if (i := text.rfind(b, 0, start)) >= 0]
    ends = [i for b in SEGMENT_BREAKS if (i := text.find(b, start)) >= 0]
    return max(begins, default=0), min(ends, default=len(text))


def candidate(text, start, name, label, shell):
    if shell:
        begin, end = segment_bounds(text, start)
        tail = text[start:end]
        verb_ok = bool(READ_CMD_RE.match(text[begin:start])) and not STDOUT_REDIRECT_RE.search(tail)
    else:
        verb_ok = True
    return (name, label, verb_ok)


def skill_candidates(text, catalog, shell=True):
    """Skills whose files a tool call references, before checking the output.

    Each candidate is (name, file label, read-command flag); the label is the
    skill directory (or listed file name) used to match the output.
    """
    cands, seen = [], set()
    for start, path in skill_md_paths(text):
        if PATCH_HEADER_RE.search(text, 0, start):
            continue  # file being written by an apply_patch, not read
        name = name_for(path + "/SKILL.md", catalog)
        if name and name not in seen:
            seen.add(name)
            cands.append(candidate(text, start, name, path.rstrip("/").rsplit("/", 1)[-1], shell))
    for path, name in catalog.items():
        start = text.find(path)
        if not path.endswith("/SKILL.md") and start >= 0 and name not in seen:
            seen.add(name)
            cands.append(candidate(text, start, name, name.rsplit(":", 1)[-1], shell))
    return cands


def confirmed_loads(cands, output):
    """Candidates the tool output shows were really read."""
    whole_call_failed = output.lstrip().startswith(FAILED_OUTPUT_PREFIXES)
    names = []
    for name, label, verb_ok in cands:
        shown = re.search(r"name:\s*[\"']?" + re.escape(label) + r"(?![\w-])", output)
        missing = re.search(re.escape(label) + r"(?:/SKILL\.md)?[\"']?: No such file", output)
        if shown or (verb_ok and not whole_call_failed and not missing):
            names.append(name)
    return names


def is_human(origin):
    return not origin or as_dict(origin).get("kind", "human") == "human"


def base_dir_of(text):
    """Skill base directory from a skill body, "" if it has none, None if unknown."""
    if text.startswith(BASE_DIR_PREFIX):
        return text[len(BASE_DIR_PREFIX) :].split("\n", 1)[0].strip()
    return None if text.startswith("(Re-invocation") else ""


def claude_parse(path):
    events, offers, forks, evidence = [], set(), {}, []
    usage_idx, pending_tools = {}, {}
    pending_cmd = None  # slash command whose skill body should follow
    awaiting_body = None  # loaded skill whose body (with its base directory) comes next
    first_user_text = None
    for rec in iter_records(path):
        kind = rec.get("type")
        msg = as_dict(rec.get("message"))
        content = msg.get("content")
        if kind == "assistant":
            u = as_dict(msg.get("usage"))
            if u:
                usage = (
                    u.get("input_tokens", 0) + u.get("cache_creation_input_tokens", 0),
                    u.get("cache_read_input_tokens", 0),
                    u.get("output_tokens", 0),
                )
                # One API response is split into one record per content block.
                key = msg.get("id") or rec.get("requestId") or id(rec)
                if key in usage_idx:
                    i = usage_idx[key]
                    events[i] = ("usage",) + tuple(map(max, events[i][1:], usage))
                else:
                    usage_idx[key] = len(events)
                    events.append(("usage",) + usage)
            for c in content if isinstance(content, list) else []:
                if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") == "Skill":
                    skill = as_dict(c.get("input")).get("skill")
                    if isinstance(skill, str) and skill.strip("/"):
                        pending_tools[c.get("id")] = skill.strip("/")
        elif kind == "attachment":
            a = as_dict(rec.get("attachment"))
            if a.get("type") == "skill_listing":
                names = a.get("names") or CLAUDE_LISTED_RE.findall(str(a.get("content", "")))
                offers.update(n for n in names if isinstance(n, str))
            elif a.get("type") == "queued_command" and a.get("commandMode") == "prompt" and is_human(a.get("origin")):
                events.append(PROMPT)  # typed while the model was busy
        elif kind == "system":
            m = FORKED_LAUNCH_RE.search(str(rec.get("content", "")))
            if m:
                try:
                    launch = json.loads(m.group(1))
                except ValueError:
                    launch = {}
                if launch.get("skillName") and launch.get("agentId"):
                    events += [PROMPT, ("skill", [launch["skillName"]])]
                    forks[launch["agentId"]] = launch["skillName"]
        elif kind == "user":
            text = content_text(content)
            if first_user_text is None:
                first_user_text = text if rec.get("isMeta") else ""
            blocks = content if isinstance(content, list) else []
            tool_results = [c for c in blocks if isinstance(c, dict) and c.get("type") == "tool_result"]
            for c in tool_results:
                skill = pending_tools.pop(c.get("tool_use_id"), None)
                result = as_dict(rec.get("toolUseResult"))
                if not skill or c.get("is_error") or result.get("success") is False:
                    continue
                events.append(("skill", [skill]))
                if result.get("status") == "forked" and result.get("agentId"):
                    forks[result["agentId"]] = skill
                else:
                    awaiting_body = skill
            if tool_results:
                continue
            cmd = CMD_NAME_RE.search(text)
            if cmd:
                if is_human(rec.get("origin")):
                    events.append(PROMPT)
                pending_cmd = None
                if "<skill-format>true</skill-format>" in text:
                    events.append(("skill", [cmd.group(1)]))
                    awaiting_body = cmd.group(1)
                else:
                    pending_cmd = cmd.group(1)
            elif rec.get("isMeta"):
                if pending_cmd and text.startswith(BASE_DIR_PREFIX):
                    events.append(("skill", [pending_cmd]))
                    awaiting_body = pending_cmd
                if awaiting_body:
                    base = base_dir_of(text)
                    if base is not None:
                        evidence.append((awaiting_body, base))
                    awaiting_body = None
                pending_cmd = None
            elif is_human(rec.get("origin")) and text.strip() and not rec.get("isCompactSummary"):
                events.append(PROMPT)
                pending_cmd = None
    name = os.path.basename(path)
    agent_id = name[len("agent-") : -len(".jsonl")] if name.startswith("agent-") else None
    return dict(
        events=events, offers=offers, forks=forks, evidence=evidence, agent_id=agent_id, first_meta=first_user_text
    )


def codex_catalog(text):
    """Parses the "Available skills" list Codex puts in its developer message."""
    roots = dict(CODEX_ROOT_RE.findall(text))
    catalog = {}
    for name, file in CODEX_LISTED_RE.findall(text):
        root, _, rest = file.partition("/")
        catalog[normalize_path(f"{roots[root]}/{rest}" if root in roots else file)] = name
    return catalog


def is_codex_prompt(text):
    s = text.lstrip()
    return bool(s) and (not s.startswith(("<", "# AGENTS.md")) or s.startswith("<user_action>"))


def codex_call_text(p):
    if p.get("type") == "custom_tool_call":
        return str(p.get("input") or "")
    raw = p.get("arguments") if p.get("type") == "function_call" else p.get("action")
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except ValueError:
            return raw
    return strings_in(raw)


def codex_parse(path):
    events, offers, pending, catalog = [], set(), {}, {}
    seen_responses, last_total, has_usage_records = set(), None, False
    cutoff = None  # records before this ordinal are history copied from a parent thread
    for rec in iter_records(path):
        kind = rec.get("type")
        p = as_dict(rec.get("payload"))
        ptype = str(p.get("type", ""))
        if kind == "session_meta" and cutoff is None:
            cutoff = p.get("subagent_history_start_ordinal") or p.get("forked_from_ordinal_exclusive") or 0
            continue
        copied = isinstance(rec.get("ordinal"), int) and rec["ordinal"] < (cutoff or 0)
        if kind == "response_item" and ptype == "message":
            text = content_text(p.get("content"))
            if p.get("role") in ("developer", "system", "user") and "(file: " in text:
                listed = codex_catalog(text)
                catalog.update(listed)
                if not copied:
                    offers.update(listed.values())
            if copied or p.get("role") != "user":
                continue
            blocks = CODEX_SKILL_BLOCK_RE.findall(text)
            if blocks:
                events.append(("skill", [n.strip() for n, _ in blocks]))
            elif is_codex_prompt(text):
                events.append(PROMPT)
        elif copied:
            continue
        elif kind == "event_msg" and ptype in ("task_started", "user_message"):
            events.append(PROMPT)
        elif kind == "token_usage_record":
            has_usage_records = True
            rid = p.get("response_id")
            if rid in seen_responses:
                continue
            seen_responses.add(rid)
            u = as_dict(p.get("usage"))
            cached = u.get("cached_input_tokens", 0)
            events.append(("usage", u.get("input_tokens", 0) - cached, cached, u.get("output_tokens", 0)))
        elif kind == "event_msg" and ptype == "token_count":
            info = as_dict(p.get("info"))
            total, u = info.get("total_token_usage"), as_dict(info.get("last_token_usage"))
            if u and total != last_total:
                last_total = total
                cached = u.get("cached_input_tokens", 0)
                events.append(("token_count", u.get("input_tokens", 0) - cached, cached, u.get("output_tokens", 0)))
        elif kind == "response_item" and ptype in ("custom_tool_call", "function_call", "local_shell_call"):
            if ptype == "local_shell_call" or p.get("name") in CODEX_SHELL_TOOLS:
                cands = skill_candidates(codex_call_text(p), catalog)
                if cands:
                    pending[p.get("call_id")] = cands
        elif kind == "response_item" and ptype.endswith("_output"):
            cands = pending.pop(p.get("call_id"), None)
            names = confirmed_loads(cands, strings_in(p.get("output"))) if cands else []
            if names:
                events.append(("skill", names))
    return dict(events=fix_codex_usage(events, has_usage_records), offers=offers)


def fix_codex_usage(events, has_usage_records):
    """Uses token_count events only when the file has no token_usage_record.

    Those older files write a response's token_count after its tool outputs, so
    a skill load waits for the next token_count; otherwise the call that read
    the skill would be charged to it.
    """
    if has_usage_records:
        return [ev for ev in events if ev[0] != "token_count"]
    out, deferred = [], []
    for ev in events:
        if ev[0] == "skill":
            deferred.append(ev)
            continue
        if ev[0] == "prompt":
            out += deferred
            deferred = []
        out.append(("usage",) + ev[1:] if ev[0] == "token_count" else ev)
        if ev[0] == "token_count":
            out += deferred
            deferred = []
    return out + deferred


def pi_parse(path):
    events, offers, pending, catalog = [], set(), {}, {}
    for rec in iter_records(path):
        msg = rec.get("message")
        if rec.get("type") != "message" or not isinstance(msg, dict):
            continue
        role = msg.get("role")
        if role == "system":
            text = as_dict(msg.get("sections")).get("skills") or content_text(msg.get("content"))
            for name, location in PI_LISTED_RE.findall(str(text)):
                catalog[normalize_path(location.strip())] = name.strip()
                offers.add(name.strip())
        elif role == "user":
            events.append(PROMPT)
            names = [n for n, _ in PI_SKILL_BLOCK_RE.findall(content_text(msg.get("content")))]
            if names:
                events.append(("skill", names))
        elif role == "assistant":
            u = as_dict(msg.get("usage"))
            if u:
                events.append(("usage", u.get("input", 0) + u.get("cacheWrite", 0), u.get("cacheRead", 0), u.get("output", 0)))
            content = msg.get("content")
            for c in content if isinstance(content, list) else []:
                if not isinstance(c, dict) or c.get("type") != "toolCall":
                    continue
                args = as_dict(c.get("arguments"))
                if c.get("name") == "read" and isinstance(args.get("path"), str):
                    target = args["path"]
                    name = catalog.get(normalize_path(target)) or (
                        name_for(target, catalog) if target.endswith("/SKILL.md") else None
                    )
                    cands = [(name, canonical(name), True)] if name else []
                elif c.get("name") == "bash":
                    cands = skill_candidates(strings_in(args), catalog)
                else:
                    cands = []
                if cands:
                    pending[c.get("id")] = cands
        elif role == "toolResult":
            cands = pending.pop(msg.get("toolCallId"), None)
            if cands and not msg.get("isError"):
                names = confirmed_loads(cands, content_text(msg.get("content")))
                if names:
                    events.append(("skill", names))
    return dict(events=events, offers=offers)


PARSERS = {"claude": claude_parse, "codex": codex_parse, "pi": pi_parse}


def parse_file(job):
    harness, path = job
    try:
        info = PARSERS[harness](path)
        info["day"] = datetime.fromtimestamp(os.path.getmtime(path), timezone.utc).strftime("%Y-%m-%d")
        return harness, path, info
    except ZstdUnavailable:
        return harness, path, "zstd"
    except OSError as e:
        return harness, path, f"skipped: {e}"


def session_stats(events, base=None):
    """Returns {skill: [calls, input, cached input, output]} for one session."""
    stats = defaultdict(lambda: [0, 0, 0, 0])
    base = [base] if base else []
    current, seen, turn_active, last = list(base), set(), False, None
    for ev in events:
        kind = ev[0]
        if kind == "prompt":
            # Consecutive prompt-like messages with no model call between them
            # (e.g. Codex's task_started plus the user message) are one boundary.
            if turn_active:
                current, seen, turn_active = list(base), set(), False
        elif kind == "skill":
            group = current if last == "skill" else []
            for name in ev[1]:
                if canonical(name) not in {canonical(n) for n in group}:
                    group.append(name)
                if canonical(name) not in seen:
                    seen.add(canonical(name))
                    stats[name][0] += 1
            current = group
        elif kind == "usage":
            turn_active = True
            for i, name in enumerate(current):
                for k, v in enumerate(ev[1:], start=1):
                    share, rem = divmod(v, len(current))
                    stats[name][k] += share + (1 if i < rem else 0)
        last = kind
    return dict(stats)


def session_id(path):
    """A key that stays the same across hosts and archiving: the UUID-bearing file name."""
    parts = path.split("/")
    name = parts[-1][: -len(".zst")] if parts[-1].endswith(".zst") else parts[-1]
    if UUID_RE.search(name) or name.startswith("agent-"):
        return name
    for i in range(len(parts) - 2, -1, -1):  # e.g. Pi's <uuid>/run-0/session.jsonl
        if UUID_RE.search(parts[i]):
            return "/".join(parts[i:-1] + [name])
    return path


def resolve_claude(results):
    """Links forked-skill transcripts to their skill and marks Claude Code built-in skills."""
    forks = {}
    for _, info in results:
        forks.update(info["forks"])
    evidence = []
    bases = {}
    for _, info in results:
        evidence += info["evidence"]
        skill = forks.get(info["agent_id"])
        if skill:
            bases[id(info)] = skill
            body = info["first_meta"] or ""
            if body:
                base = base_dir_of(body)
                if base is not None:
                    evidence.append((skill, base))
    file_based = {n for n, d in evidence if d and "/bundled-skills/" not in d}
    builtin = {n for n, d in evidence if ":" not in n and (not d or "/bundled-skills/" in d)} - file_based

    def rename(name):
        return BUILTIN_PREFIX + name if name in builtin else name

    for _, info in results:
        info["events"] = [(ev[0], [rename(n) for n in ev[1]]) if ev[0] == "skill" else ev for ev in info["events"]]
        info["offers"] = {rename(n) for n in info["offers"]}
        info["base"] = rename(bases[id(info)]) if id(info) in bases else None


def scan(args):
    sources = {
        "claude": [f"{args.claude_dir}/projects/**/*.jsonl"],
        "codex": [f"{args.codex_dir}/sessions/**/*.jsonl*", f"{args.codex_dir}/archived_sessions/**/*.jsonl*"],
        "pi": [f"{args.pi_dir}/sessions/**/*.jsonl"],
    }
    jobs = []
    for harness in args.only.split(","):
        if harness not in sources:
            sys.exit(f"unknown harness {harness!r}; choose from {', '.join(sources)}")
        jobs += [(harness, f) for f in sorted({f for pat in sources[harness] for f in glob.glob(pat, recursive=True)})]
    if args.jobs == 1:
        parsed = list(map(parse_file, jobs))
    else:
        with ProcessPoolExecutor(max_workers=args.jobs) as pool:
            parsed = list(pool.map(parse_file, jobs, chunksize=4))

    results, zstd_missing = defaultdict(list), 0
    for harness, path, info in parsed:
        if info == "zstd":
            zstd_missing += 1
        elif isinstance(info, str):
            print(f"{info}: {path}", file=sys.stderr)
        else:
            results[harness].append((path, info))
    if zstd_missing:
        print(
            f"skipped {zstd_missing} compressed sessions: install the `zstandard` module or `zstd`, "
            f"or run `uv run --with zstandard python {sys.argv[0]} ...`",
            file=sys.stderr,
        )
    resolve_claude(results["claude"])

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    sessions, offered = {}, {}
    for harness, items in results.items():
        for path, info in items:
            for skill in info["offers"]:
                add_offer(offered, dict(host=args.host, harness=harness, skill=skill, last_seen=info["day"]))
            sid = session_id(path)
            sessions[(harness, sid)] = dict(
                host=args.host,
                harness=harness,
                session=sid,
                path=path,
                scanned_at=now,
                skills=session_stats(info["events"], info.get("base")),
            )
    return sessions, offered


def add_offer(offered, o):
    key = (o["host"], o["harness"], o["skill"])
    if key not in offered or o["last_seen"] > offered[key]["last_seen"]:
        offered[key] = o


def load_snapshot(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if data.get("format") not in READABLE_FORMATS:
        sys.exit(f"{path}: not a skill-usage snapshot")
    sessions = {(s["harness"], s["session"]): s for s in data["sessions"]}
    offered = {}
    for o in data.get("offered", []):
        add_offer(offered, o)
    return sessions, offered


def merge_sessions(dst, src):
    """Adds src into dst; a session seen in both keeps its most recent scan."""
    for key, s in src.items():
        if key not in dst or s["scanned_at"] >= dst[key]["scanned_at"]:
            dst[key] = s


def save_snapshot(path, sessions, offered):
    session_rows = [json.dumps(s) for s in sorted(sessions.values(), key=lambda s: (s["harness"], s["session"]))]
    offered_rows = [json.dumps(offered[k]) for k in sorted(offered)]
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        # One record per line keeps the file diffable and greppable.
        f.write(f'{{"format": "{SNAPSHOT_FORMAT}",\n"offered": [\n' + ",\n".join(offered_rows) + "\n],\n")
        f.write('"sessions": [\n' + ",\n".join(session_rows) + "\n]}\n")
    os.replace(tmp, path)
    print(f"saved {len(sessions)} sessions to {path}", file=sys.stderr)


def human(n):
    for unit, size in (("B", 1e9), ("M", 1e6), ("k", 1e3)):
        if n >= size:
            return f"{n / size:.1f}{unit}"
    return str(n)


def main():
    if hasattr(signal, "SIGPIPE"):
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)  # quiet exit when piped into head
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("snapshots", nargs="*", help="saved snapshots to merge instead of scanning this machine")
    ap.add_argument("--scan", action="store_true", help="also scan this machine when snapshots are given")
    ap.add_argument("--save", metavar="FILE", help="write the combined per-session data as a snapshot")
    ap.add_argument("--host", default=socket.gethostname(), help="host label recorded in scanned sessions")
    ap.add_argument("--only", default="claude,codex,pi", help="comma-separated harnesses to scan (default: all)")
    ap.add_argument("--claude-dir", default=os.environ.get("CLAUDE_CONFIG_DIR", f"{HOME}/.claude"))
    ap.add_argument("--codex-dir", default=CODEX_HOME)
    ap.add_argument("--pi-dir", default=os.environ.get("PI_CODING_AGENT_DIR", f"{HOME}/.pi/agent"))
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 1, help="parallel parser processes")
    ap.add_argument("--merge", action="store_true", help="combine harnesses into one row per skill")
    ap.add_argument("--by-host", action="store_true", help="split rows by host")
    ap.add_argument("--native-names", action="store_true", help="show each harness's own skill names")
    ap.add_argument("--include-unused", action="store_true", help="also list offered skills with 0 calls")
    ap.add_argument("--json", action="store_true", help="print JSON instead of a table")
    args = ap.parse_args()

    sessions, offered = {}, {}
    sources = [load_snapshot(path) for path in args.snapshots]
    if args.scan or not args.snapshots:
        sources.append(scan(args))
    for src_sessions, src_offered in sources:
        merge_sessions(sessions, src_sessions)
        for o in src_offered.values():
            add_offer(offered, o)
    if args.save:
        save_snapshot(args.save, sessions, offered)

    def key(host, harness, skill):
        return (
            ((host,) if args.by_host else ())
            + ("all" if args.merge else harness,)
            + (skill if args.native_names else canonical(skill),)
        )

    stats = defaultdict(lambda: [0, 0, 0, 0])  # calls, input, cached input, output
    for s in sessions.values():
        for skill, row in s["skills"].items():
            total = stats[key(s["host"], s["harness"], skill)]
            for i, v in enumerate(row):
                total[i] += v
    last_offered = {}
    if args.include_unused:
        for o in offered.values():
            k = key(o["host"], o["harness"], o["skill"])
            stats[k]  # adds a zero row for skills never called
            last_offered[k] = max(last_offered.get(k, ""), o["last_seen"])
    rows = sorted(stats.items(), key=lambda kv: (kv[0][:-1], -sum(kv[1][1:]), -kv[1][0], kv[0][-1]))

    labels = (("host",) if args.by_host else ()) + ("harness", "skill")
    if args.json:
        out = [
            dict(zip(labels, k), calls=c, input=i, cached_input=ci, output=o, total=i + ci + o)
            | ({"last_offered": last_offered.get(k)} if args.include_unused else {})
            for k, (c, i, ci, o) in rows
        ]
        json.dump(out, sys.stdout, indent=2)
        print()
        return
    header = tuple(l.upper() for l in labels) + ("CALLS", "INPUT", "CACHED", "OUTPUT", "TOTAL")
    header += ("LAST OFFERED",) if args.include_unused else ()
    table = [header] + [
        k
        + (str(c), human(i), human(ci), human(o), human(i + ci + o))
        + ((last_offered.get(k, "-"),) if args.include_unused else ())
        for k, (c, i, ci, o) in rows
    ]
    widths = [max(len(r[n]) for r in table) for n in range(len(header))]
    for r in table:
        print("  ".join(v.ljust(w) if n < len(labels) else v.rjust(w) for n, (v, w) in enumerate(zip(r, widths))))


if __name__ == "__main__":
    main()
