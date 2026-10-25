#!/usr/bin/env python3
"""Refresh the generated source seed and record the Y source hashes it contains."""
import hashlib
import json
import pathlib
import sys

def write_changed(path, data):
    if not path.exists() or path.read_bytes() != data:
        path.write_bytes(data)


root = pathlib.Path(__file__).resolve().parents[2]
write_changed(root / 'bootstrap/ycc.c', pathlib.Path(sys.argv[1]).read_bytes())
manifest = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted((root / 'src/y').glob('*.y'))}
write_changed(root / 'bootstrap/sources.json', (json.dumps(manifest, indent=2) + '\n').encode())
