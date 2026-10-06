#!/usr/bin/env python3
"""
Script to build the standalone self-extracting shell script for RHEL 9.8 / Linux.
It embeds the XZ-compressed DuckDB Linux x86_64 binary into view_vpc_flow_logs.sh.
"""

import os
import lzma
import base64
import sys

def build():
    root_dir = os.path.dirname(os.path.abspath(__file__))
    bin_path = os.path.join(root_dir, "bin", "duckdb")
    template_path = os.path.join(root_dir, "view_vpc_flow_logs.template.sh")
    output_path = os.path.join(root_dir, "view_vpc_flow_logs.sh")

    if not os.path.exists(bin_path):
        print(f"Error: {bin_path} does not exist", file=sys.stderr)
        sys.exit(1)

    print(f"Reading Linux DuckDB binary from {bin_path}...")
    with open(bin_path, "rb") as f:
        raw_binary = f.read()

    print(f"Original size: {len(raw_binary):,} bytes")
    print("Compressing with XZ (preset 6)...")
    xz_data = lzma.compress(raw_binary, preset=6)
    print(f"Compressed size: {len(xz_data):,} bytes")

    print("Encoding with Base64...")
    b64_data = base64.b64encode(xz_data).decode("ascii")
    # Wrap base64 lines at 76 characters
    b64_lines = [b64_data[i:i+76] for i in range(0, len(b64_data), 76)]
    wrapped_b64 = "\n".join(b64_lines)

    print(f"Reading template from {template_path}...")
    with open(template_path, "r", encoding="utf-8") as f:
        template_content = f.read()

    full_script = template_content.replace("__EMBEDDED_PAYLOAD_PLACEHOLDER__", wrapped_b64)

    print(f"Writing standalone script to {output_path}...")
    with open(output_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(full_script)

    print(f"Successfully generated {output_path} ({os.path.getsize(output_path):,} bytes)")

if __name__ == "__main__":
    build()
