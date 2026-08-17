#!/usr/bin/env python3
"""Query AMD LLM API usage stats per day."""

import argparse
import csv
import functools
import io
import json
import os
import urllib.error
import urllib.request
import urllib.parse
from concurrent.futures import ThreadPoolExecutor
from datetime import date, timedelta

BASE_URL = "https://llm-api.amd.com/api/UsageStats"
REQUEST_TIMEOUT_SECONDS = 30

PROVIDER_LABEL = {
    "AzureOpenAI": "AzureOpenAI",
    "VertexGenAI": "Vertex",
    "OnPremLLM": "OnPrem",
}

COLS = ["Provider", "Model", "Requests", "Prompt Tokens", "Completion Tokens", "Total Tokens", "Cost"]


# ── data fetching ──────────────────────────────────────────────────────────────

def fetch_usage(
    start: date,
    end: date,
    api_key: str,
    timeout: float = REQUEST_TIMEOUT_SECONDS,
) -> dict:
    params = urllib.parse.urlencode({"start": start.isoformat(), "end": end.isoformat()})
    req = urllib.request.Request(
        f"{BASE_URL}?{params}",
        headers={"Ocp-Apim-Subscription-Key": api_key},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return {"message": "No usage data."}
        raise


def daily_query_bounds(day: date) -> tuple[date, date]:
    """Return the API's bounds for exactly one calendar day.

    UsageStats treats start/end as midnight timestamps with an *exclusive*
    end, i.e. the window is [day 00:00, next-day 00:00).  Passing (day, day)
    is a zero-width window that the API rejects with 404, so the end bound
    must be the following day.
    """
    return day, day + timedelta(days=1)


# ── formatting helpers ─────────────────────────────────────────────────────────

def fmt_int(n) -> str:
    return f"{n:,}"

def fmt_usd(n) -> str:
    return f"${n:,.4f}"

def build_rows(stats: dict) -> list[tuple]:
    rows = []
    for provider, models in stats.items():
        label = PROVIDER_LABEL.get(provider, provider)
        for m in models:
            prompt = m.get("promptTokens", 0)
            compl  = m.get("completionTokens", 0)
            total  = m.get("totalTokens", 0)
            rows.append((
                label,
                m["model"],
                fmt_int(m["totalRequests"]),
                fmt_int(prompt) if prompt else "—",
                fmt_int(compl)  if compl  else "—",
                fmt_int(total)  if total  else "—",
                fmt_usd(m.get("approxChargeInUSD", 0)),
            ))
    return rows


# ── table renderers ────────────────────────────────────────────────────────────

def _col_widths(headers, rows, total_row=None):
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(str(cell)))
    if total_row:
        for i, cell in enumerate(total_row):
            widths[i] = max(widths[i], len(str(cell)))
    return widths

def _align(cell, width, col_idx):
    s = str(cell)
    return f"{s:>{width}}" if col_idx >= 2 else f"{s:<{width}}"


def render_box(headers, rows, total_row=None, rounded=False):
    w = _col_widths(headers, rows, total_row)
    tl, tr, bl, br = ("╭", "╮", "╰", "╯") if rounded else ("┌", "┐", "└", "┘")

    def border(l, m, r, f="─"):
        return l + m.join(f * (wi + 2) for wi in w) + r

    def row_str(cells):
        return "│" + "│".join(f" {_align(c, w[i], i)} " for i, c in enumerate(cells)) + "│"

    lines = [border(tl, "┬", tr), row_str(headers)]
    for row in rows:
        lines += [border("├", "┼", "┤"), row_str(row)]
    if total_row:
        lines += [border("╞", "╪", "╡", "═"), row_str(total_row)]
    lines.append(border(bl, "┴", br))
    return "\n".join(lines)


def render_simple(headers, rows, total_row=None):
    w = _col_widths(headers, rows, total_row)

    def row_str(cells):
        return "  " + "  ".join(_align(c, w[i], i) for i, c in enumerate(cells))

    def sep():
        return "  " + "  ".join("-" * wi for wi in w)

    lines = [row_str(headers), sep()]
    for row in rows:
        lines.append(row_str(row))
    if total_row:
        lines += [sep(), row_str(total_row)]
    return "\n".join(lines)


def render_markdown(headers, rows, total_row=None):
    w = _col_widths(headers, rows, total_row)

    def row_str(cells):
        return "| " + " | ".join(_align(c, w[i], i) for i, c in enumerate(cells)) + " |"

    def sep():
        parts = [("-" * wi) if i < 2 else ("-" * (wi - 1)) + ":" for i, wi in enumerate(w)]
        return "| " + " | ".join(parts) + " |"

    lines = [row_str(headers), sep()]
    for row in rows:
        lines.append(row_str(row))
    if total_row:
        lines += [sep(), row_str(total_row)]
    return "\n".join(lines)


def render_dsv(headers, rows, total_row=None, delimiter=","):
    buf = io.StringIO()
    w = csv.writer(buf, delimiter=delimiter)
    w.writerow(headers)
    for row in rows:
        w.writerow(row)
    if total_row:
        w.writerow(total_row)
    return buf.getvalue().rstrip()


RENDERERS = {
    "box":         render_box,
    "box-rounded": functools.partial(render_box, rounded=True),
    "simple":      render_simple,
    "markdown":    render_markdown,
    "csv":         functools.partial(render_dsv, delimiter=","),
    "tsv":         functools.partial(render_dsv, delimiter="\t"),
}

FORMATS = tuple(RENDERERS)

def render_table(fmt, headers, rows, total_row=None):
    return RENDERERS[fmt](headers, rows, total_row)


# ── output sections ────────────────────────────────────────────────────────────

def print_summary(summaries, fmt):
    headers = ["Date", "Requests", "Total Tokens", "Cost (USD)"]
    rows, grand_req, grand_tok, grand_cost = [], 0, 0, 0

    for d, data in summaries:
        label = d.strftime("%b %d (%a)")
        if "message" in data:
            rows.append((label, "—", "—", "—"))
        else:
            reqs = data["totalRequests"]
            toks = data["totalTokens"]
            cost = data["approxChargeInUSD"]
            grand_req += reqs; grand_tok += toks; grand_cost += cost
            rows.append((label, fmt_int(reqs), fmt_int(toks), fmt_usd(cost)))

    total_row = ("TOTAL", fmt_int(grand_req), fmt_int(grand_tok), fmt_usd(grand_cost))
    print(render_table(fmt, headers, rows, total_row))


def print_day(label, data, fmt):
    total_req  = data.get("totalRequests", 0)
    total_tok  = data.get("totalTokens", 0)
    total_cost = data.get("approxChargeInUSD", 0)

    print(f"\n  {label}  |  {fmt_int(total_req)} requests  |  {fmt_usd(total_cost)}\n")

    stats = data.get("stats", {})
    if not stats:
        print("  No data.")
        return

    rows = build_rows(stats)
    total_row = ("", "TOTAL", fmt_int(total_req), "—", "—", fmt_int(total_tok), fmt_usd(total_cost))
    print(render_table(fmt, COLS, rows, total_row))


# ── CLI ────────────────────────────────────────────────────────────────────────

def _parse_date_arg(value, today, flag, parser):
    try:
        return today + timedelta(days=int(value))
    except ValueError:
        pass
    try:
        return date.fromisoformat(value)
    except ValueError:
        parser.error(f"Invalid value for {flag}: {value!r}. Expected YYYY-MM-DD or an integer offset.")


def resolve_date_bounds(start_date, end_date, days, today):
    """Resolve the inclusive dates to display, including today by default."""
    has_start = start_date is not None
    has_end = end_date is not None
    has_days = days is not None
    if has_start and has_end and has_days:
        raise ValueError(
            "--start, --end, and --days cannot all be specified together "
            "(overdetermined)."
        )

    day_count = days if has_days else 3
    if day_count < 1:
        raise ValueError("--days must be at least 1")

    if has_start and has_end:
        pass
    elif has_start:
        end_date = (
            start_date + timedelta(days=day_count - 1)
            if has_days
            else today
        )
    elif has_end:
        start_date = end_date - timedelta(days=day_count - 1)
    else:
        end_date = today
        start_date = end_date - timedelta(days=day_count - 1)

    if start_date > end_date:
        raise ValueError(f"--start ({start_date}) must not be after --end ({end_date}).")
    return start_date, end_date


def main():
    parser = argparse.ArgumentParser(
        prog="llm_usage.py",
        description="Query AMD LLM API usage stats per day.",
        epilog=(
            "Date range rules: specify any two of --start/--end/--days; the third is derived. "
            "Specifying all three is an error. "
            "Dates accept YYYY-MM-DD or an integer offset relative to today (e.g. -1 = yesterday)."
        ),
    )
    parser.add_argument("--start", metavar="DATE|N",
                        help="Start date: YYYY-MM-DD or offset from today (-7 = a week ago)")
    parser.add_argument("--end", metavar="DATE|N",
                        help="End date: YYYY-MM-DD or offset from today (-1 = yesterday). Default: today")
    parser.add_argument("--days", type=int, default=None, metavar="N",
                        help="Number of days to show (default: 3)")
    parser.add_argument("--key", metavar="KEY",
                        help="API key (overrides LLM_GATEWAY_KEY env var)")
    parser.add_argument("--format", dest="fmt", choices=FORMATS, default="box",
                        help="Output format (default: box)")
    args = parser.parse_args()

    api_key = args.key or os.environ.get("LLM_GATEWAY_KEY")
    if not api_key:
        parser.error("API key not provided. Use --key <key> or set the LLM_GATEWAY_KEY environment variable.")

    today = date.today()
    start_date = (
        _parse_date_arg(args.start, today, "--start", parser)
        if args.start is not None else None
    )
    end_date = (
        _parse_date_arg(args.end, today, "--end", parser)
        if args.end is not None else None
    )
    try:
        start_date, end_date = resolve_date_bounds(
            start_date, end_date, args.days, today
        )
    except ValueError as exc:
        parser.error(str(exc))

    date_range = [start_date + timedelta(days=i) for i in range((end_date - start_date).days + 1)]

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(
            # UsageStats' end bound is exclusive midnight, so d..d+1 selects
            # exactly calendar day d (see daily_query_bounds).
            lambda d: fetch_usage(*daily_query_bounds(d), api_key),
            date_range,
        ))
    summaries = list(zip(date_range, results, strict=True))

    account = next(
        (d.get("application", {}).get("name", "") for _, d in summaries if "application" in d),
        "",
    )
    date_label = (start_date.strftime("%b %d") + " – " + end_date.strftime("%b %d")
                  if start_date != end_date else start_date.strftime("%b %d"))
    print(f"\n  AMD LLM API Usage — {date_label}  ({len(date_range)} day{'s' if len(date_range) != 1 else ''})"
          f"{f'  (account: {account})' if account else ''}\n")

    print_summary(summaries, args.fmt)

    for d, data in summaries:
        if "message" in data:
            continue
        print_day(d.strftime("%b %d (%a)"), data, args.fmt)

    print()


if __name__ == "__main__":
    main()
