#!/usr/bin/env python3
"""Compare generated-C programs with native Y for the implemented subset."""
import pathlib
import argparse
import resource
import subprocess
import tempfile
from yast import ROOT, dump_ast
from cgen import Generator


def run(command):
    return subprocess.run(command, cwd=ROOT, stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bootstrap',type=pathlib.Path)
    options=parser.parse_args()
    resource.setrlimit(resource.RLIMIT_AS, (3670016 * 1024,) * 2)
    compiler = ROOT / 'ynew'
    cases = ['t01_arith', 't02_recursion', 't03_while', 't05_cmp_bool',
             't26_closures', 't54_capture_cells', 't39_incdec_opassign',
             't11_array', 't21_records']
    with tempfile.TemporaryDirectory(prefix='ycc-cgen-test-') as tmp:
        scratch = pathlib.Path(tmp)
        sources = [ROOT / 'test/y/native' / (name + '.y') for name in cases]
        sources += sorted((ROOT / 'tools/bootstrap/fixtures').glob('*.y'))
        for source in sources:
            name = source.stem
            tree = dump_ast(compiler, source, scratch)
            (scratch / 'generated.c').write_text(Generator().generate(tree))
            cc = run(['gcc', '-std=gnu99', '-O0', '-Itools/bootstrap', '-Isrc/c',
                      str(scratch / 'generated.c'), 'src/c/yv.c', 'src/c/host.c',
                      '-lm', '-o', str(scratch / 'hosted')])
            assert cc.returncode == 0, cc.stderr.decode()
            native = run([str(compiler), '--gc=auto', '-o', str(scratch / 'native'), str(source)])
            assert native.returncode == 0, native.stdout.decode()
            expected, actual = run([str(scratch / 'native')]), run([str(scratch / 'hosted')])
            assert (actual.returncode, actual.stdout) == (expected.returncode, expected.stdout), (
                name, actual.returncode, actual.stdout, expected.returncode, expected.stdout)
            print('PASS', name)
        if options.bootstrap:
            source=ROOT / 'test/y/examples/helloworld.y'
            compiled=run([str(options.bootstrap.resolve()),'-o',str(scratch / 'hosted'),str(source)])
            assert compiled.returncode==0, (compiled.stdout,compiled.stderr)
            native=run([str(compiler),'-o',str(scratch / 'native'),str(source)])
            assert native.returncode==0, native.stdout
            expected,actual=run([str(scratch / 'native')]),run([str(scratch / 'hosted')])
            assert (actual.returncode,actual.stdout)==(expected.returncode,expected.stdout)
            print('PASS generated compiler compiles Hello World')
            for source in sorted((ROOT / 'test/y/native').glob('e39[0-3]_bootstrap_*.y')):
                command = ['-o', str(scratch / 'rejected'), str(source)]
                expected = run([str(compiler)] + command)
                actual = run([str(options.bootstrap.resolve())] + command)
                assert expected.returncode == actual.returncode == 1, (expected, actual)
                assert actual.stdout == expected.stdout, (actual.stdout, expected.stdout)
                print('PASS generated compiler rejects', source.stem)


if __name__ == '__main__':
    main()
