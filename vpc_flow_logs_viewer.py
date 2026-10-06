#!/usr/bin/env python3
"""
AWS VPC Flow Logs (Parquet) Viewer - Python CLI Tool
Compatible with DuckDB and PyArrow.
Cross-platform support for Linux (RHEL 9.8) and Windows 11.
"""

import argparse
import glob
import os
import sys
from datetime import datetime

def format_bytes(b):
    if b >= 1024**4: return f"{b / (1024**4):.2f} TB"
    if b >= 1024**3: return f"{b / (1024**3):.2f} GB"
    if b >= 1024**2: return f"{b / (1024**2):.2f} MB"
    if b >= 1024:    return f"{b / 1024:.2f} KB"
    return f"{b} B"

def protocol_name(proto):
    mapping = {
        1: 'ICMP', 2: 'IGMP', 6: 'TCP', 17: 'UDP',
        41: 'IPv6', 47: 'GRE', 50: 'ESP', 51: 'AH',
        58: 'ICMPv6', 89: 'OSPF'
    }
    return mapping.get(int(proto), str(proto))

def tcp_flags_str(flags):
    if flags == 0: return '-'
    names = []
    if flags & 1:  names.append('FIN')
    if flags & 2:  names.append('SYN')
    if flags & 4:  names.append('RST')
    if flags & 8:  names.append('PSH')
    if flags & 16: names.append('ACK')
    if flags & 32: names.append('URG')
    return '-'.join(names) if names else str(flags)

def main():
    parser = argparse.ArgumentParser(description="AWS VPC Flow Logs (Parquet) Viewer")
    parser.add_argument("path", help="Path to .parquet file or directory containing .parquet files")
    parser.add_argument("-a", "--action", choices=["ALL", "ACCEPT", "REJECT"], default="ALL", help="Filter by action")
    parser.add_argument("-p", "--protocol", help="Filter by protocol name (TCP, UDP, ICMP) or number (6, 17, 1)")
    parser.add_argument("-s", "--src", help="Filter by source IP")
    parser.add_argument("-d", "--dst", help="Filter by destination IP")
    parser.add_argument("-i", "--ip", help="Filter by source or destination IP")
    parser.add_argument("--srcport", type=int, default=0, help="Filter by source port")
    parser.add_argument("--dstport", type=int, default=0, help="Filter by destination port")
    parser.add_argument("--port", type=int, default=0, help="Filter by port (source or destination)")
    parser.add_argument("-l", "--limit", type=int, default=0, help="Limit number of output rows")
    parser.add_argument("--sort", choices=["time", "bytes", "packets", "src", "dst"], default="time", help="Sort by field")
    parser.add_argument("--order", choices=["ASC", "DESC"], default="ASC", help="Sort order")
    parser.add_argument("-f", "--format", choices=["table", "detail", "csv", "tsv", "json"], default="table", help="Output format")
    parser.add_argument("-o", "--output", help="Save output to file")
    parser.add_argument("--stats", action="store_true", help="Display summary statistics dashboard")
    parser.add_argument("--all-columns", action="store_true", help="Display all columns")
    parser.add_argument("--no-recurse", action="store_true", help="Do not search subdirectories recursively")

    args = parser.parse_args()

    # Verify input path
    target = os.path.abspath(args.path)
    if not os.path.exists(target):
        print(f"Error: Path does not exist: {target}", file=sys.stderr)
        sys.exit(1)

    # Detect engine (DuckDB preferred)
    try:
        import duckdb
        has_duckdb = True
    except ImportError:
        has_duckdb = False

    if not has_duckdb:
        try:
            import pyarrow.parquet as pq
            has_pyarrow = True
        except ImportError:
            has_pyarrow = False
            print("Error: Neither 'duckdb' nor 'pyarrow' is installed.", file=sys.stderr)
            sys.exit(1)

    # Resolve files
    if os.path.isdir(target):
        if args.no_recurse:
            parquet_files = glob.glob(os.path.join(target, "*.parquet"))
        else:
            parquet_files = glob.glob(os.path.join(target, "**", "*.parquet"), recursive=True)
    else:
        parquet_files = [target]

    if not parquet_files:
        print(f"Error: No .parquet files found in {target}", file=sys.stderr)
        sys.exit(1)

    # Use DuckDB for processing
    con = duckdb.connect()
    files_sql = "', '".join([f.replace("\\", "/") for f in parquet_files])
    table_expr = f"read_parquet(['{files_sql}'], union_by_name=true)"

    # Build WHERE clauses
    where = []
    if args.action and args.action != "ALL":
        where.append(f"action = '{args.action}'")
    if args.protocol:
        proto_map = {'ICMP': 1, 'IGMP': 2, 'TCP': 6, 'UDP': 17, 'IPV6': 41, 'GRE': 47, 'ESP': 50, 'AH': 51, 'ICMPV6': 58, 'OSPF': 89}
        if args.protocol.isdigit():
            where.append(f"protocol = {args.protocol}")
        elif args.protocol.upper() in proto_map:
            where.append(f"protocol = {proto_map[args.protocol.upper()]}")
        else:
            where.append(f"protocol = '{args.protocol}'")
    if args.src:
        where.append(f"srcaddr = '{args.src}'")
    if args.dst:
        where.append(f"dstaddr = '{args.dst}'")
    if args.ip:
        where.append(f"(srcaddr = '{args.ip}' OR dstaddr = '{args.ip}')")
    if args.srcport > 0:
        where.append(f"srcport = {args.srcport}")
    if args.dstport > 0:
        where.append(f"dstport = {args.dstport}")
    if args.port > 0:
        where.append(f"(srcport = {args.port} OR dstport = {args.port})")

    where_sql = ("WHERE " + " AND ".join(where)) if where else ""

    # Check available columns
    desc_rows = con.execute(f"DESCRIBE SELECT * FROM {table_expr} LIMIT 1").fetchall()
    cols = [r[0] for r in desc_rows]
    has_flags = 'tcp_flags' in cols
    has_dir = 'flow_direction' in cols
    has_vpc = 'vpc_id' in cols

    # Summary Statistics Mode
    if args.stats:
        stats_sql = f"""
        SELECT 
            count(*) as flows,
            coalesce(sum(packets), 0) as packets,
            coalesce(sum(bytes), 0) as bytes,
            count(*) FILTER (WHERE action = 'ACCEPT') as accept_cnt,
            count(*) FILTER (WHERE action = 'REJECT') as reject_cnt,
            coalesce(strftime(to_timestamp(min(start)), '%Y-%m-%d %H:%M:%S'), '-') as min_t,
            coalesce(strftime(to_timestamp(max(columns('^end$'))), '%Y-%m-%d %H:%M:%S'), '-') as max_t
        FROM {table_expr} {where_sql};
        """
        st = con.execute(stats_sql).fetchone()

        top_src = con.execute(f"SELECT srcaddr, count(*), sum(packets), sum(bytes) FROM {table_expr} {where_sql} GROUP BY srcaddr ORDER BY sum(bytes) DESC LIMIT 5").fetchall()
        top_dst = con.execute(f"SELECT dstaddr, count(*), sum(packets), sum(bytes) FROM {table_expr} {where_sql} GROUP BY dstaddr ORDER BY sum(bytes) DESC LIMIT 5").fetchall()
        top_ports = con.execute(f"SELECT dstport, count(*), sum(bytes) FROM {table_expr} {where_sql} GROUP BY dstport ORDER BY count(*) DESC LIMIT 5").fetchall()
        proto_stats = con.execute(f"SELECT protocol, count(*), sum(packets), sum(bytes) FROM {table_expr} {where_sql} GROUP BY protocol ORDER BY count(*) DESC").fetchall()

        lines = [
            "=" * 80,
            " AWS VPC Flow Logs - Summary Statistics Dashboard",
            "=" * 80,
            f" Target Path      : {target}",
            f" Parquet Files    : {len(parquet_files)} file(s)",
            f" Time Range       : {st[5]} ~ {st[6]}",
            f" Total Flows      : {st[0]:,}",
            f" Total Packets    : {st[1]:,}",
            f" Total Bytes      : {format_bytes(st[2])} ({st[2]:,} bytes)",
            f" ACCEPT Flows     : {st[3]:,} ({(st[3]/st[0]*100 if st[0] else 0):.1f}%)",
            f" REJECT Flows     : {st[4]:,} ({(st[4]/st[0]*100 if st[0] else 0):.1f}%)",
            "",
            "--- Top 5 Source IPs (by Bytes) ---",
        ]
        for r in top_src:
            lines.append(f"  {r[0]:<18} {r[1]:>6} flows   {r[2]:>8,} packets   {format_bytes(r[3]):>12}")
        lines.append("")
        lines.append("--- Top 5 Destination IPs (by Bytes) ---")
        for r in top_dst:
            lines.append(f"  {r[0]:<18} {r[1]:>6} flows   {r[2]:>8,} packets   {format_bytes(r[3]):>12}")
        lines.append("")
        lines.append("--- Top 5 Destination Ports (by Flows) ---")
        for r in top_ports:
            lines.append(f"  Port {r[0]:<10} {r[1]:>6} flows   {format_bytes(r[2]):>12}")
        lines.append("")
        lines.append("--- Protocol Breakdown ---")
        for r in proto_stats:
            p_name = protocol_name(r[0])
            lines.append(f"  {p_name:<10} {r[1]:>6} flows   {r[2]:>8,} packets   {format_bytes(r[3]):>12}")
        lines.append("=" * 80)

        out_text = "\n".join(lines)
        print(out_text)
        if args.output:
            with open(args.output, "w", encoding="utf-8") as f:
                f.write(out_text)
            print(f"Summary statistics saved to: {args.output}")
        return

    # Sort & Limit
    sort_map = {'bytes': 'bytes', 'packets': 'packets', 'src': 'srcaddr', 'dst': 'dstaddr', 'time': 'start'}
    sort_col = sort_map.get(args.sort, 'start')
    order_sql = f"ORDER BY {sort_col} {args.order}"
    limit_sql = f"LIMIT {args.limit}" if args.limit > 0 else ""

    if args.all_columns:
        query = f"SELECT * FROM {table_expr} {where_sql} {order_sql} {limit_sql};"
    else:
        select_parts = [
            "strftime(to_timestamp(start), '%Y-%m-%d %H:%M:%S') AS start_time",
            "strftime(to_timestamp(columns('^end$')), '%Y-%m-%d %H:%M:%S') AS end_time",
            "action",
            """CASE protocol 
                WHEN 1 THEN 'ICMP' WHEN 2 THEN 'IGMP' WHEN 6 THEN 'TCP' 
                WHEN 17 THEN 'UDP' WHEN 41 THEN 'IPv6' WHEN 47 THEN 'GRE' 
                WHEN 50 THEN 'ESP' WHEN 58 THEN 'ICMPv6' ELSE CAST(protocol AS VARCHAR) 
            END AS proto""",
            "srcaddr || ':' || CAST(srcport AS VARCHAR) AS source",
            "dstaddr || ':' || CAST(dstport AS VARCHAR) AS destination",
            "packets",
            "bytes"
        ]
        if has_flags:
            select_parts.append("""CASE tcp_flags 
                WHEN 1 THEN 'FIN' WHEN 2 THEN 'SYN' WHEN 4 THEN 'RST' 
                WHEN 16 THEN 'ACK' WHEN 18 THEN 'SYN-ACK' WHEN 0 THEN '-' 
                ELSE CAST(tcp_flags AS VARCHAR) 
            END AS flags""")
        if has_dir:
            select_parts.append("flow_direction AS dir")
        select_parts.extend(["interface_id", "log_status"])
        if has_vpc:
            select_parts.append("vpc_id")

        query = f"SELECT {', '.join(select_parts)} FROM {table_expr} {where_sql} {order_sql} {limit_sql};"

    # Format selection
    if args.format == "csv":
        df = con.execute(query).df()
        out_str = df.to_csv(index=False)
        print(out_str)
    elif args.format == "tsv":
        df = con.execute(query).df()
        out_str = df.to_csv(index=False, sep="\t")
        print(out_str)
    elif args.format == "json":
        df = con.execute(query).df()
        out_str = df.to_json(orient="records", indent=2)
        print(out_str)
    elif args.format == "detail":
        records = con.execute(query).fetchall()
        col_names = [d[0] for d in con.description]
        out_lines = []
        for i, rec in enumerate(records, 1):
            out_lines.append(f"--- Record #{i} ---")
            for c, v in zip(col_names, rec):
                if c == "bytes":
                    v = f"{format_bytes(v)} ({v:,} bytes)"
                out_lines.append(f"  {c:<16}: {v}")
        out_str = "\n".join(out_lines)
        print(out_str)
    else: # table
        records = con.execute(query).fetchall()
        col_names = [d[0] for d in con.description]
        formatted_rows = []
        for rec in records:
            row = list(rec)
            if 'bytes' in col_names:
                b_idx = col_names.index('bytes')
                row[b_idx] = format_bytes(row[b_idx])
            formatted_rows.append([str(v) for v in row])

        # Calculate widths
        widths = [len(c) for c in col_names]
        for row in formatted_rows:
            for i, val in enumerate(row):
                widths[i] = max(widths[i], len(val))

        header = " | ".join(c.ljust(widths[i]) for i, c in enumerate(col_names))
        sep = "-+-".join("-" * widths[i] for i in range(len(col_names)))
        data_lines = [" | ".join(row[i].ljust(widths[i]) for i in range(len(col_names))) for row in formatted_rows]

        out_lines = [
            f"Processed {len(parquet_files)} Parquet file(s). Displaying {len(records)} record(s):\n",
            header,
            sep
        ] + data_lines
        out_str = "\n".join(out_lines)
        print(out_str)

    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(out_str)
        print(f"\nOutput saved to: {args.output}")

if __name__ == "__main__":
    main()
