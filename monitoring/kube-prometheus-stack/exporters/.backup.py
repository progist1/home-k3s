#!/usr/bin/env python3
"""
backup_to_prom.py

Usage:
  backup_to_prom.py /path/to/report.json /path/to/output.prom [--error-threshold HOURS]

Exports Prometheus-compatible metrics about backup freshness and status.

If first arg is a directory, scans for latest file per section (optional behaviour).
By default writes to /var/lib/node_exporter/textfile_collector/backup_status.prom
"""
from __future__ import annotations
import sys
import json
import os
import datetime
import argparse

DEFAULT_OUT = "/var/lib/prometheus/node-exporter/backups.prom"
ERROR_THRESHOLD = 30  # hours default

def esc(s: str) -> str:
    # escape label values for Prometheus exposition format
    return s.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def write_prom(path: str, lines: list[str]):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, path)


def parse_report_json(path: str):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def timestamp_to_dt(ts: str) -> datetime.datetime:
    # expected "YYYY-MM-DDTHH:MM:SS"
    return datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("report", help="path to directory with reports")
    ap.add_argument("out", nargs="?", default=DEFAULT_OUT, help="output .prom file")
    ap.add_argument("--error-threshold", type=float, default=ERROR_THRESHOLD,
                    help="hours considered error (default 30)")
    args = ap.parse_args()

    now = datetime.datetime.now()
    out_lines: list[str] = []

    # HELP / TYPE headers
    out_lines += [
        '# HELP backup_age_hours Age in hours since last backup (lower is better)',
        '# TYPE backup_age_hours gauge',
        '# HELP backup_missing Whether backup exists (1 = missing, 0 = ok)',
        '# TYPE backup_missing gauge',
        '# HELP backups_total_count Number of recorded backup entries per section',
        '# TYPE backups_total_count gauge',
        '# HELP backup_last_taken_at Unix timestamp of last successful backup',
        '# TYPE backup_last_taken_at gauge',
        '# HELP backup_size_bytes Size of the last successful backup in bytes',
        '# TYPE backup_size_bytes gauge',
    ]

    if not os.path.isdir(args.report):
        print("Provided not a directory", file=sys.stderr)
        sys.exit(2)

    reports = ["backup_report.json", "sync_report.json"]

    # Собираем все данные сначала
    section_counts = {}
    all_backups_total = 0

    for report_file in reports:
        report_path = os.path.join(args.report, report_file)
        if not os.path.exists(report_path):
            print(f"No such file or directory: {report_path}", file=sys.stderr)
            continue  # Продолжаем с другим файлом вместо выхода

        report = parse_report_json(report_path)
        backups = report.get("backups", {})
        requirements = report.get("requirements", {})

        # Суммируем счетчики по секциям
        for section, items in backups.items():
            count = len(items) if items else 0
            section_counts[section] = section_counts.get(section, 0) + count
            all_backups_total += count

        # per-item metrics (остается как есть)
        for section, items in requirements.items():
            for name, info in items.items():
                labels = f'section="{esc(section)}",name="{esc(name)}",type="{report_file.split(".")[0]}"'
                if info is None:
                    out_lines.append(f'backup_missing{{{labels}}} 1')
                    out_lines.append(f'backup_age_hours{{{labels}}} -1')
                    continue

                try:
                    taken = timestamp_to_dt(info["taken_at"])
                    ts_unix = int(taken.timestamp())
                except Exception:
                    out_lines.append(f'backup_missing{{{labels}}} 1')
                    out_lines.append(f'backup_age_hours{{{labels}}} -1')
                    continue

                age_h = (now - taken).total_seconds() / 3600.0
                over = 1 if age_h > args.error_threshold else 0

                out_lines.append(f'backup_missing{{{labels}}} 0')
                out_lines.append(f'backup_age_hours{{{labels}}} {age_h:.2f}')
                out_lines.append(
                    f'backup_age_over_threshold{{{labels},threshold_hours="{args.error_threshold}"}} {over}')
                out_lines.append(f'backup_last_taken_at{{{labels}}} {ts_unix}')

                # optional backup size
                size = info.get("size_bytes") or info.get("size") or 0
                if size:
                    out_lines.append(f'backup_size_bytes{{{labels}}} {size}')

    # Записываем агрегированные счетчики ОДИН РАЗ
    for section, count in section_counts.items():
        out_lines.append(f'backups_total_count{{section="{esc(section)}"}} {count}')

    out_lines.append(f'backups_total_count{{section="all"}} {all_backups_total}')

    write_prom(args.out, out_lines)
    print(f"Wrote {len(out_lines)} metrics to {args.out}")

if __name__ == "__main__":
    main()
