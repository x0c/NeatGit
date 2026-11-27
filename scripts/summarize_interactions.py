#!/usr/bin/env python3
"""把 xctrace 导出的 os-signpost XML 汇总成交互耗时统计。仅使用 Python 标准库。"""

from __future__ import annotations

import argparse
import json
import math
import statistics
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

SUBSYSTEM = "io.github.x0c.neatgit"
CATEGORY = "Interaction"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="汇总 NeatGit 交互 signpost 的 P50/P95/最大耗时")
    parser.add_argument("xml", type=Path, help="xctrace export 得到的 os-signpost XML")
    parser.add_argument("--json", dest="json_path", type=Path, help="可选：把明细与汇总写成 JSON")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    root = ET.parse(args.xml).getroot()
    intervals: dict[tuple[str, str, str], int] = {}
    samples: dict[str, list[dict[str, float | bool]]] = defaultdict(list)
    incomplete = 0
    # XML 里每张表的 id 都是独立命名空间；不能用一张全局 ref 表配对不同 instrument。
    for table in root.iter("node"): 
        values: dict[str, str] = {}
        raw_values: dict[str, str] = {}
        for element in table.iter():
            identifier = element.get("id")
            if identifier is not None:
                values[identifier] = element.get("fmt") or element.text or ""
                raw_values[identifier] = element.text or ""

        def value(row: ET.Element, tag: str) -> str:
            element = row.find(tag)
            if element is None:
                return ""
            if reference := element.get("ref"):
                return values.get(reference, "")
            return element.get("fmt") or element.text or ""

        for row in table.iter("row"):
            if value(row, "subsystem") != SUBSYSTEM or value(row, "category") != CATEGORY:
                continue
            event_type = value(row, "event-type")
            if event_type not in {"Begin", "End"}:
                continue
            name = value(row, "signpost-name")
            identifier = value(row, "os-signpost-identifier")
            thread = value(row, "thread")
            key = (identifier, name, thread)
            time_element = row.find("event-time")
            raw_time = (time_element.text if time_element is not None else None) or ""
            if not raw_time and time_element is not None and (reference := time_element.get("ref")):
                raw_time = raw_values.get(reference, "")
            timestamp = int(raw_time or "0")
            if event_type == "Begin":
                intervals[key] = timestamp
                continue
            started_at = intervals.pop(key, None)
            if started_at is None:
                incomplete += 1
                continue
            samples[name].append({
                "milliseconds": (timestamp - started_at) / 1_000_000,
                "main_thread": "Main Thread" in thread,
            })
    incomplete += len(intervals)

    summary = []
    for name, items in sorted(samples.items()):
        durations = sorted(float(item["milliseconds"]) for item in items)
        summary.append({
            "name": name,
            "count": len(durations),
            "mainThreadCount": sum(1 for item in items if item["main_thread"]),
            "p50Milliseconds": statistics.median(durations),
            "p95Milliseconds": durations[max(0, math.ceil(len(durations) * 0.95) - 1)],
            "maxMilliseconds": durations[-1],
        })

    print("区间\t次数\t主线程\tP50(ms)\tP95(ms)\t最大(ms)")
    for item in summary:
        print(
            f"{item['name']}\t{item['count']}\t{item['mainThreadCount']}\t"
            f"{item['p50Milliseconds']:.3f}\t{item['p95Milliseconds']:.3f}\t{item['maxMilliseconds']:.3f}"
        )
    if not summary:
        print("没有匹配的应用交互区间。")
    if incomplete:
        print(f"未配对区间：{incomplete}（录制开始/结束截断或任务尚未结束）")

    if args.json_path:
        args.json_path.parent.mkdir(parents=True, exist_ok=True)
        args.json_path.write_text(
            json.dumps({"summary": summary, "incompleteIntervals": incomplete}, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )


if __name__ == "__main__":
    main()
