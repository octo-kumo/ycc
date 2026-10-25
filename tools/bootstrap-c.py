#!/usr/bin/env python3
"""Generate GNU99 C from a Y program (bootstrap backend under construction)."""
import argparse
import pathlib
import resource
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).parent / 'bootstrap'))
from yast import dump_ast
from cgen import Generator


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=pathlib.Path)
    parser.add_argument('-o', '--output', type=pathlib.Path, required=True)
    parser.add_argument('--compiler', type=pathlib.Path, default=pathlib.Path('./ynew'))
    args = parser.parse_args()
    resource.setrlimit(resource.RLIMIT_AS, (3670016 * 1024,) * 2)
    with tempfile.TemporaryDirectory(prefix='ycc-cgen-') as scratch:
        tree = dump_ast(args.compiler.resolve(), args.source, pathlib.Path(scratch))
        generated = Generator().generate(tree)
        args.output.write_text(generated)


if __name__ == '__main__':
    main()
