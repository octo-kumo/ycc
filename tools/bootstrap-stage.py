#!/usr/bin/env python3
"""Build the first generation with a compiler predating isolated meta files.

Expansion is build output: the maintained compiler stays in src/y. Subsequent
self-compiles read that source directly and use the compiler's own meta pass.
"""
import argparse
import pathlib
import resource
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compiler", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    compiler = args.compiler.resolve()
    output = args.output.resolve()
    resource.setrlimit(resource.RLIMIT_AS, (3670016 * 1024,) * 2)
    with tempfile.TemporaryDirectory(prefix="ycc-bootstrap-") as scratch:
        source = pathlib.Path(scratch) / "src" / "y"
        shutil.copytree("src/y", source)
        # The seed predates process-ending regions. Generation one uses its
        # collector; subsequent generations check and emit the real entrypoint.
        entry = source / "ycc.y"
        entry.write_text(entry.read_text().replace(
            "region { exit(main(argv())); }", "exit(main(argv()));"))
        for original in sorted(pathlib.Path("src/y").glob("*.y")):
            # Compiler generators are isolated modules with a column-zero block.
            if not any(line.startswith("#{") for line in original.read_text().splitlines()):
                continue
            expanded = subprocess.run(
                [str(compiler), "--emit=source", str(original)], stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, check=True, timeout=120,
            ).stdout
            (source / original.name).write_bytes(expanded)
        subprocess.run(
            [str(compiler), "--std=source", "--gc=auto", "-o", str(output), str(source / "ycc.y")],
            stdin=subprocess.DEVNULL, check=True, timeout=180,
        )


if __name__ == "__main__":
    main()
