#!/usr/bin/env python3
"""Unpack and format XML contents of Office files (.docx, .pptx, .xlsx)"""

import os
import random
import sys
import defusedxml.minidom
import zipfile
from pathlib import Path

# Get command line arguments
assert len(sys.argv) == 3, "Usage: python unpack.py <office_file> <output_dir>"
input_file, output_dir = sys.argv[1], sys.argv[2]

# Extract and format
output_path = Path(output_dir)
output_path.mkdir(parents=True, exist_ok=True)

# Safe extraction with zip-slip protection
with zipfile.ZipFile(input_file) as zf:
    real_output = os.path.realpath(str(output_path))
    for member in zf.namelist():
        dest = os.path.realpath(os.path.join(real_output, member))
        if not dest.startswith(real_output + os.sep) and dest != real_output:
            raise ValueError(f"Zip slip detected: {member}")
    zf.extractall(output_path)

# Pretty print all XML files
xml_files = list(output_path.rglob("*.xml")) + list(output_path.rglob("*.rels"))
for xml_file in xml_files:
    content = xml_file.read_text(encoding="utf-8")
    dom = defusedxml.minidom.parseString(content)
    xml_file.write_bytes(dom.toprettyxml(indent="  ", encoding="ascii"))

# For .docx files, suggest an RSID for tracked changes
if input_file.endswith(".docx"):
    suggested_rsid = "".join(random.choices("0123456789ABCDEF", k=8))
    print(f"Suggested RSID for edit session: {suggested_rsid}")
