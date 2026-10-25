"""Use Y's parser and renamer, rather than reimplementing the language in Python."""
import json
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]


def exporter_source():
    source = (ROOT / 'src/y/parser.y').read_text()
    records = dict(re.findall(r'^type (\w+) = \{ (.*?) \};', source, re.M))
    unions = dict(re.findall(r'^type (\w+) = (\w+(?: \| \w+)+);', source, re.M))
    shapes = re.findall(r'^    "([^"]+)",', (ROOT / 'src/y/ast_schema.y').read_text(), re.M)
    node_members = []
    for shape in shapes:
        name, *fields = shape.split()
        node_members.append(name)
        records[name] = 'k: long, line: long, col: long' + ''.join(', ' + f.replace(':', ': ') for f in fields)
    unions['Node'] = ' | '.join(node_members)
    type_members = []
    for shape in re.findall(r'^    "([^"]+)",', (ROOT / 'src/y/type_schema.y').read_text(), re.M):
        name, *fields = shape.split()
        type_members.append(name)
        if name != 'Err':
            records[name] = 'k: long' + ''.join(', ' + f.replace(':', ': ') for f in fields)
    unions['Type'] = ' | '.join(type_members)
    required = {'Node', 'Type'}
    pending = list(required)
    while pending:
        name = pending.pop()
        if name in unions:
            children = unions[name].split(' | ')
        else:
            children = re.findall(r': (?:\[)?(\w+)', records[name])
        for child in children:
            if child not in {'long', 'str', 'bool'} and child not in required:
                required.add(child)
                pending.append(child)
    code = [f'import parser from "{ROOT}/src/y/parser.y";',
            f'import resolver from "{ROOT}/src/y/rename.y";',
            f'import nativelib from "{ROOT}/src/y/native.y";',
            f'import meta from "{ROOT}/src/y/meta.y";',
            f'import checked from "{ROOT}/src/y/types.y";', 'import json;', 'import fs;',
            'def quoted(s: str) -> str { "\\\"" + json.escape(s) + "\\\"" };']

    def encode(expr, typ):
        if typ == 'str':
            return f'quoted({expr})'
        if typ in {'long', 'bool'}:
            return f'tostring({expr})'
        if typ.startswith('['):
            return f'array_{typ[1:-1]}({expr})'
        return f'dump_{typ}({expr})'

    arrays = set()
    for name in sorted(required):
        if name == 'Type':
            # Renamed recursive aliases have back-links. C's boxed prototype
            # does not need expanded layouts; never serialize those cycles.
            code.append('''def dump_Type(v: Type) -> str {
                v = checked.unfold(v);
                let out = "{\\\"k\\\":" + tostring(v.k) + ",\\\"tag\\\":" + quoted(ktag(v.k));
                if (v.k == K.tarr) { let a: TOf = v; out += ",\\\"element\\\":\\\"" + ktag(a.of.k) + "\\\""; };
                if (v.k == K.tarrfix) { let a: TFix = v; out += ",\\\"element\\\":\\\"" + ktag(a.of.k) + "\\\""; };
                if (v.k == K.trec || v.k == K.tpat) {
                    let names: [str] = [];
                    if (v.k == K.trec) { let r: TRec = v; foreach (f in r.fields) { names += f.name; }; }
                    else { let r: TPat = v; names = r.names; };
                    out += ",\\\"fields\\\":" + array_str(names);
                };
                out + "}"
            };''')
        elif name in unions:
            arms = ',\n'.join(f'{part} v => dump_{part}(v)' for part in unions[name].split(' | '))
            if name == 'Node':
                code.append(f'def dump_Node(v: Node) -> str {{ let text = match v {{ {arms} }}; text[:len(text)-1] + ",\\\"inferred\\\":" + dump_Type(checked.heap_type(v.line,v.col,v.k)) + "}}" }};')
            else:
                code.append(f'def dump_{name}(v: {name}) -> str {{ match v {{ {arms} }} }};')
        else:
            fields = re.findall(r'(\w+): (\[\w+\]|\w+)', records[name])
            expressions = []
            for key, typ in fields:
                if typ.startswith('['):
                    arrays.add(typ[1:-1])
                expressions += [json.dumps(json.dumps(key) + ':'), encode('v.' + key, typ)]
            if any(key == 'k' for key, _ in fields):
                expressions += [json.dumps('"tag":'), 'quoted(ktag(v.k))']
            # Put separators between fields, not between a key and its value.
            pairs = [expressions[i] + ' + ' + expressions[i+1] for i in range(0, len(expressions), 2)]
            code.append(f'def dump_{name}(v: {name}) -> str {{ "{{" + ' + ' + "," + '.join(pairs) + ' + "}" };')
    for typ in sorted(arrays):
        code.append(f'''def array_{typ}(xs: [{typ}]) -> str {{
            let out = "["; let sep = "";
            foreach (v in xs) {{ out += sep + {encode('v', typ)}; sep = ","; }};
            out + "]"
        }};''')
    code += ['let args = argv();', 'let text = unwrap(fs.read_file(args[1]));',
             'meta.meta_begin();',
             'let nr = nativelib.native_resolve_x(text, args[2], 0, true, args[1]);',
             'let parsed = parser.parse_program(lexer.tokenize(nr.src));',
             'let units = nativelib.std_units(nr.std, "");',
             'let ext = nativelib.unit_externs(units, nr.std, [], nr.pkgs);',
             'nativelib.unit_prep(ext);',
             'let stripped: Block = nativelib.strip_ns(parsed, nr.imports);',
             'let tree = resolver.rename_program_x(stripped, ext.dfl, nr.origin.file, nr.origin.mods);',
             'checked.heap_index_on();',
             'let errors = checked.check_program(tree, ext.ext);',
             'if (len(errors) > 0) { foreach (e in errors) { eputs(e.msg); }; exit(1); };',
             'let root: Node = tree;',
             'puts(dump_Node(root));']
    # lexer is imported explicitly: parser's path import only supplies types.
    code.insert(1, f'import lexer from "{ROOT}/src/y/lexer.y";')
    return '\n'.join(code) + '\n'


def dump_ast(compiler, source, scratch):
    helper = scratch / 'dump.y'
    helper.write_text(exporter_source())
    subprocess.run([str(compiler), '--gc=auto', '-o', str(scratch / 'dump'), str(helper)],
                   stdin=subprocess.DEVNULL, check=True, timeout=120)
    output = subprocess.run([str(scratch / 'dump'), str(source.resolve()), str(source.resolve().parent)],
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            check=True, timeout=120).stdout
    return json.loads(output.decode('utf-8','surrogateescape'))
