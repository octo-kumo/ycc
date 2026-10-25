"""GNU99 emission from Y's renamed AST; unsupported forms fail explicitly."""
import re

def kind(node):
    return node['tag']


def quote(s):
    # C octal escapes preserve arbitrary UTF-8 bytes and cannot swallow digits.
    return '"' + ''.join(chr(c) if 32 <= c < 127 and c not in (34, 92)
                         else '\\%03o' % c for c in s.encode('utf-8','surrogateescape')) + '"'


class Generator:
    def __init__(self):
        self.functions = []
        self.serial = 0
        self.types = {}
        self.variables = {}
        self.globals = set()
        self.captured = set()

    def bindings(self, tree):
        """Renamed identifiers are unique: only cross-function locals need cells."""
        owners = {}
        uses = []
        self.globals = {n['name'] for n in tree['stmts'] if kind(n) == 'decl'}

        def visit(node, owner=None):
            if isinstance(node, list):
                for child in node: visit(child, owner)
            elif isinstance(node, dict):
                tag = node.get('tag')
                if tag == 'func':
                    owner = id(node)
                    for name in node['params']: owners[name] = owner
                if tag in {'decl', 'forrange', 'foreach'}:
                    owners[node['name']] = owner
                if tag in {'id', 'assign'}:
                    uses.append((node['v'] if tag == 'id' else node['name'], owner))
                for child in node.values(): visit(child, owner)

        visit(tree)
        self.captured = {name for name, owner in uses
                         if name in owners and owners[name] != owner and name not in self.globals}
        self.variables = {name: 'cg_var_' + str(i) for i, name in enumerate(owners)
                          if name not in self.captured}

    def read(self, name):
        if name == 'self': return 'closure'
        return self.variables.get(name, f'cg_get(env,{quote(name)})')

    def store(self, name, value, define=False):
        if name in self.variables:
            return f'({self.variables[name]}={value})'
        return f'cg_{"define" if define else "set"}(env,{quote(name)},{value})'

    def local_declarations(self, node):
        names = []
        def visit(n):
            if isinstance(n, list):
                for child in n: visit(child)
            elif isinstance(n, dict) and n.get('tag') != 'func':
                if n.get('tag') in {'decl', 'forrange', 'foreach'}:
                    name = n['name']
                    if name in self.variables and name not in self.globals: names.append(name)
                for child in n.values(): visit(child)
        visit(node)
        return ''.join(f'Yv *{self.variables[name]}=NULL;' for name in names)

    def scope(self):
        return 'CgEnv *parent=env;CgEnv *env __attribute__((cleanup(cg_env_drop)))=cg_scope(parent);'

    def binary(self, op, a, b, left, right):
        integers = {'tlong', 'tbyte', 'tbool'}
        if left.get('tag') in integers and right.get('tag') in integers:
            x = f'yv_truth({a})' if left['tag'] == 'tbool' else f'yv_l({a})'
            y = f'yv_truth({b})' if right['tag'] == 'tbool' else f'yv_l({b})'
            if op in {'==', '!=', '<', '>', '<=', '>='}: return f'yv_bool({x}{op}{y})'
            if op in {'+', '-', '*', '&', '|', '^'}:
                return f'yv_long((ylong)((uint64_t){x}{op}(uint64_t){y}))'
        code = {'==':'EQ','!=':'NE','in':'IN','+':'ADD','-':'SUB','*':'MUL','/':'DIV',
                '%':'MOD','<':'LT','>':'GT','<=':'LE','>=':'GE','&':'AND','|':'OR',
                '^':'XOR','<<':'SHL','>>':'SHR','>>>':'USHR'}[op]
        return f'cg_bin(CG_{code},{a},{b})'

    def array(self, node, expected=None):
        typ=expected if expected and expected.get('tag') in {'tarr','tarrfix'} else self.type_of(node)
        packed=typ.get('element')=='tbyte'
        if kind(node)=='arrrep':
            fn='cg_bytes_repeat' if packed else 'ya_rep'
            return f'{fn}({self.expr(node["v"])},{node["n"]})'
        return self.seq([self.expr(e) for e in node['elems']],lambda x:
            f'cg_bytes({len(x)},(Yv*[]){{'+','.join(x)+'})' if packed else
            f'yav({len(x)}'+(' ,'+','.join(x) if x else '')+')')

    def temp(self):
        self.serial += 1
        return 'v' + str(self.serial)

    def seq(self, expressions, result):
        names = [self.temp() for _ in expressions]
        setup = ''.join(f'Yv *{n}={e};' for n,e in zip(names, expressions))
        return '({' + setup + result(names) + ';})'

    def captures(self, node, name, inside=False):
        if isinstance(node, list):
            return any(self.captures(child, name, inside) for child in node)
        if not isinstance(node, dict):
            return False
        inside = inside or node.get('tag') == 'func'
        if inside and (node.get('tag') == 'id' and node.get('v') == name
                       or node.get('tag') == 'assign' and node.get('name') == name):
            return True
        return any(self.captures(child, name, inside) for child in node.values())

    def fn(self, node, binding='lambda'):
        name = 'cg_fn_' + re.sub(r'[^a-zA-Z0-9_]', '_', binding) + '_' + str(len(self.functions))
        self.functions.append('')
        index = len(self.functions)-1
        params = ''.join((f'Yv *{self.variables[p]}=args[{i}];' if p in self.variables else
                          self.store(p, f'args[{i}]', True) + ';') for i,p in enumerate(node['params']))
        env = ('CgEnv *env __attribute__((cleanup(cg_env_drop)))=cg_scope(f->env);'
               if any(p in self.captured for p in node['params']) else 'CgEnv *env=f->env;')
        native = {'y_host_machine': 'yv_long(cg_host_machine())',
                  'y_bytes_zero': 'ya_bytes_zero(yv_l(args[0]))',
                  'y_copy_fwd': 'cg_copy_fwd(args[0],args[1],args[2])'}
        body = native.get(node.get('label')) or self.expr(node['body'])
        self.functions[index] = (f'static Yv *{name}(Yv *closure,size_t argc,Yv **args) {{'
            f'if(argc!={len(node["params"])}){{fputs("bootstrap: argument count\\n",stderr);exit(1);}}'
            'CgClosure *f=(CgClosure *)(intptr_t)yv_l(closure);' + env + params
            + self.local_declarations(node['body']) + f'return {body};}}')
        return f'cg_func({name},env,{len(node["params"])})'

    def place(self, node, value):
        k = kind(node)
        if k == 'id':
            return self.store(node['v'], value)
        if k == 'dot':
            return self.seq([self.expr(node['obj']),value],lambda x:f'yr_set({x[0]},{quote(node["key"])},{x[1]});{x[1]}')
        if k == 'index':
            return self.seq([self.expr(node['arr']),self.expr(node['idx']),value],lambda x:f'ya_set({x[0]},yv_l({x[1]}),{x[2]});{x[2]}')
        raise ValueError('unsupported assignment place: '+k)

    def type_of(self,n):
        k=kind(n)
        inferred=n.get('inferred',{})
        if inferred.get('tag') not in {None,'tunk','tnone'}: return inferred
        if k=='id': return self.types.get(n['v'],{})
        if k=='array':
            element=self.type_of(n['elems'][0]).get('tag') if n['elems'] else None
            return {'tag':'tarr','element':element}
        if k=='slice': return self.type_of(n['arr'])
        if k=='index': return {'tag':self.type_of(n['arr']).get('element')}
        if k=='num':
            v=n['v'].replace('_','')
            if any(c in v for c in '.eE') and not v.startswith(('0x','0X')): return {'tag':'tfloat'}
        return {'tag':{'num':'tlong','str':'tstr','rec':'trec','func':'tfunc'}.get(k)}

    def update(self, target, op, rhs, prefix=True, rhs_type=None):
        k=kind(target)
        rhs_type=rhs_type or {}
        target_type=self.type_of(target)
        old=self.temp();value=self.temp();result=self.temp()
        if k=='id':
            setup='';read=self.read(target['v'])
            write=lambda v:self.store(target['v'], v)
        elif k=='dot':
            obj=self.temp();setup=f'Yv *{obj}={self.expr(target["obj"])};'
            read=f'cg_field({obj},{quote(target["key"])})'
            write=lambda v:f'yr_set({obj},{quote(target["key"])},{v})'
        elif k=='index':
            arr=self.temp();idx=self.temp()
            setup=f'Yv *{arr}={self.expr(target["arr"])};Yv *{idx}={self.expr(target["idx"])};'
            read=f'cg_index({arr},{idx})'
            write=lambda v:f'ya_set({arr},yv_l({idx}),{v})'
        else: raise ValueError('unsupported compound place '+k)
        append='ya_push' if target_type.get('element') in {'tarr','tarrfix'} and target_type.get('element')==rhs_type.get('tag') and rhs_type.get('element') not in {'tarr','tarrfix',None} else 'cg_append'
        operation=(self.binary(op,old,value,target_type,rhs_type)
                   if target_type.get('tag') in {'tlong','tbyte','tbool'} or op!='+'
                   else f'{append}({old},{value})')
        return '({'+setup+f'Yv *{old}={read};Yv *{value}={rhs};Yv *{result}={operation};'+write(result)+';'+(result if prefix else old)+';})'

    def block(self, nodes, scope=True):
        out = '({'
        if scope and any(kind(n) == 'decl' and n['name'] in self.captured for n in nodes):
            out = '({' + self.scope()
        functions = [n for n in nodes if kind(n)=='decl' and kind(n['v'])=='func']
        for n in functions:
            out += self.store(n['name'], self.fn(n['v'], n['name']), True) + ';'
        out += 'Yv *result=yv_none();'
        for n in nodes:
            if n in functions:
                continue
            out += f'result={self.expr(n)};'
        return out+'result;})'

    def expr(self,n):
        k = kind(n)
        if k in {'str','bstr','char'}:
            if k=='char': return f'cg_literal_long({int(n["v"])})'
            return f'ys({quote(n["v"])})'
        if k=='num':
            v=n['v'].replace('_','')
            if any(c in v for c in '.eE') and not v.startswith(('0x','0X')):
                return f'yv_float({v})'
            return f'cg_literal_long((ylong)UINT64_C({int(v,0) if v.startswith(("0x","0o","0b")) else int(v)}))'
        if k=='bool': return 'yv_bool('+('1' if n['v']=='true' else '0')+')'
        if k=='void': return 'yv_none()'
        if k=='id': return 'yv_none()' if n['v']=='none' else self.read(n['v'])
        if k=='block': return self.block(n['stmts'])
        if k=='func': return self.fn(n)
        if k=='decl':
            value=self.array(n['v'],n['typ']) if kind(n['v']) in {'array','arrrep'} else self.expr(n['v'])
            return '({' + self.store(n['name'], value, True) + ';yv_none();})'
        if k=='typedef': return 'yv_none()'
        if k=='narrow': return self.expr(n['e'])
        if k=='matchend': return self.expr(n['e'])
        if k=='rectest':
            typ=n['typ'];tag=typ['tag']
            if tag in {'trec','tpat'}:
                return self.seq([self.expr(n['e'])],lambda x:'yv_bool(yv_tag('+x[0]+')==Y_REC'+(f' && {x[0]}->u.r.len=={len(typ["fields"])}' if tag=='trec' else '')+''.join(' && yr_has('+x[0]+','+quote(f)+')' for f in typ['fields'])+')')
            scalars={'tlong':'Y_LONG','tbyte':'Y_LONG','tbool':'Y_BOOL','tstr':'Y_STR','tfloat':'Y_FLOAT','tarr':'Y_ARR','tnone':'Y_NONE'}
            if tag not in scalars: raise ValueError('unsupported type test '+tag)
            return self.seq([self.expr(n['e'])],lambda x:f'yv_bool(yv_tag({x[0]})=={scalars[tag]})')
        if k=='addr':
            child=n['e']
            if kind(child)!='index': raise ValueError('address of non-array place is not implemented')
            array=child['arr']
            typ=self.type_of(array)
            stride=1 if typ.get('element')=='tbyte' else 8
            return self.seq([self.expr(array),self.expr(child['idx'])],lambda x:f'cg_address({x[0]},{x[1]},{stride})')
        if k=='assign': return self.store(n['name'], self.expr(n['v']))
        if k=='ret': return f'({{return {self.expr(n["e"])};yv_none();}})'
        if k in {'break','continue'}: return '({'+k+';yv_none();})'
        if k=='un': return f'cg_un({quote(n["op"])},{self.expr(n["e"])})'
        if k=='bin':
            op=n['op']
            if op in {'&&','||'}:
                return f'yv_bool(yv_truth({self.expr(n["l"])}) {op} yv_truth({self.expr(n["r"])}))'
            return self.seq([self.expr(n['l']),self.expr(n['r'])],lambda x:self.binary(op,x[0],x[1],self.type_of(n['l']),self.type_of(n['r'])))
        if k=='if': return f'(yv_truth({self.expr(n["cond"])})?{self.expr(n["then"])}:{self.expr(n["els"]) if n["has_else"] else "yv_none()"})'
        if k=='while': return f'({{while(yv_truth({self.expr(n["cond"])})){{{self.expr(n["body"])};}}yv_none();}})'
        if k=='for': return f'({{{self.expr(n["init"])};for(;yv_truth({self.expr(n["cond"])});{self.expr(n["step"])}){{{self.expr(n["body"])};}}yv_none();}})'
        if k=='forrange':
            name = n['name']
            sync = '' if self.captures(n['body'], name) else (
                f'CgRange range __attribute__((cleanup(cg_range_sync)))={{env,{quote(name)},&i}};'
                if name in self.captured else
                f'CgLocalRange range __attribute__((cleanup(cg_local_range_sync)))={{&{self.variables[name]},&i}};')
            scope = self.scope() if name in self.captured else ''
            bind = self.store(name, 'yv_long(i)', True)
            return self.seq([self.expr(n['lo']),self.expr(n['hi'])],lambda x:f'for(ylong i=yv_l({x[0]}),end=yv_l({x[1]});i<end;++i){{{scope}{bind};{sync}{self.expr(n["body"])};}}yv_none()')
        if k=='foreach':
            scope = self.scope() if n['name'] in self.captured else ''
            return self.seq([self.expr(n['iter'])],lambda x:f'for(ylong i=0;i<yv_len({x[0]});++i){{{scope}{self.store(n["name"],f"cg_index({x[0]},yv_long(i))",True)};{self.expr(n["body"])};}}yv_none()')
        if k in {'array','arrrep'}: return self.array(n)
        if k in {'rec','map'}:
            if '...' in n['keys']:
                record = self.temp()
                def spread(values):
                    fields = ''.join(f'cg_spread({record},{value});' if key == '...'
                                     else f'yr_set({record},{quote(key)},{value});'
                                     for key, value in zip(n['keys'], values))
                    return f'Yv *{record}=yr(0);' + fields + record
                return self.seq([self.expr(v) for v in n['vals']], spread)
            if k=='rec' and len(set(n['keys']))==len(n['keys']):
                keys=','.join(quote(key) for key in n['keys'])
                return self.seq([self.expr(v) for v in n['vals']],lambda x:
                    f'static char *const cg_keys[]={{'+keys+'};'+
                    f'cg_record({len(x)},cg_keys,(Yv*[]){{'+','.join(x)+'})')
            return self.seq([self.expr(v) for v in n['vals']],lambda x:f'yr({len(x)}'+''.join(','+quote(key)+','+val for key,val in zip(n['keys'],x))+')')
        if k=='dot':
            obj=self.expr(n['obj'])
            if n['key']=='ptr' and self.type_of(n['obj']).get('tag') in {'tarr','tarrfix'}:
                stride = 1 if self.type_of(n['obj']).get('element') == 'tbyte' else 8
                return f'cg_address({obj},cg_literal_long(0),{stride})'
            return f'yv_long(yv_len({obj}))' if n['key']=='length' else f'cg_field({obj},{quote(n["key"])})'
        if k=='index': return self.seq([self.expr(n['arr']),self.expr(n['idx'])],lambda x:f'cg_index({x[0]},{x[1]})')
        if k=='slice': return self.seq([self.expr(n[f]) for f in ('arr','lo','hi')],lambda x:'cg_slice('+','.join(x)+')')
        if k=='idxassign': return self.place(dict(tag='index',arr=n['arr'],idx=n['idx']),self.expr(n['v']))
        if k=='dotassign': return self.place(dict(tag='dot',obj=n['obj'],key=n['key']),self.expr(n['v']))
        if k=='opassign':
            value=self.expr(n['v'])
            return self.update(n['tgt'],n['op'],value,rhs_type=self.type_of(n['v']))
        if k=='incdec':
            return self.update(n['tgt'],'+' if n['op']=='++' else '-', 'yv_long(1)',n['pre'])
        if k=='call': return self.call(n)
        raise ValueError(f'unsupported AST form {k} at {n.get("line")}:{n.get("col")}')

    def call(self,n):
        args=[self.expr(a) for a in n['args']]
        name=n['callee'].get('v','') if kind(n['callee'])=='id' else ''
        if kind(n['callee'])=='dot':
            dot=n['callee'];key=dot['key'];obj=dot['obj']
            if kind(obj)=='id' and obj['v']=='fs':
                name='fs.'+key
            else:
                methods={'contains':'yv_bool(yv_tag({0})==Y_STR?ys_index_of({0},{1})>=0:yv_l(cg_find({0},{1}))>=0)','index':'cg_find({0},{1})','pop':'cg_pop({0})','some':'cg_iter({0},{1},1)','all':'cg_iter({0},{1},2)','map':'cg_iter({0},{1},3)','filter':'cg_iter({0},{1},4)','sort':'cg_sort({0},{1},0)','sorted':'cg_sort({0},{1},1)','reduce':'cg_reduce({0},{1},{2})','foreach':'cg_iter({0},{1},0)','split':'ys_split({0},{1})',
                         'join':'ys_join({0},{1})','trim':'ys_trim({0})',
                         'starts_with':'yv_bool(ys_starts_with({0},{1}))',
                         'ends_with':'yv_bool(ys_ends_with({0},{1}))',
                         'index_of':'yv_long(ys_index_of({0},{1}))',
                         'last_index_of':'yv_long(ys_last_index_of({0},{1}))'}
                if key in methods: return self.seq([self.expr(obj)]+args,lambda x:methods[key].format(*x))
        direct={'fs.read_file':'read_file({0})','fs.write_file':'yv_bool(write_file({0},{1}))',
                'fs.getenv':'fs_getenv({0})',
                'fs.make_dir':'fs_make_dir({0},yv_l({1}))',
                'fs.make_dirs':'fs_make_dirs({0})',
                'fs.is_dir':'fs_is_dir({0})',
                'fs.is_file':'fs_is_file({0})',
                'fs.remove_dir':'fs_remove_dir({0})',
                'fs.open_file':'fs_open_file({0},{1})',
                'fs.read_some':'fs_read_some(yv_l({0}),yv_l({1}))',
                'fs.close_file':'fs_close_file(yv_l({0}))',
                'fs.read_bytes':'fs_read_bytes({0})',
                'fs.list_dir':'fs_list_dir({0})',
                'fs.read_all_bytes':'read_all_bytes(yv_l({0}))',
                'wait_pid':'yv_long(wait_pid(yv_l({0})))',
                'fs.write_data':'yv_bool(write_data(yv_l({0}),{1}))',
                'fs.write_bytes':'yv_bool(write_bytes({0},{1},yv_l({2})))',
                'fs.remove_file':'yv_bool(remove_file({0}))','fs.exists':'yv_bool(access({0}->u.s.p,F_OK)==0)',
                'len':'yv_long(yv_len({0}))','tostring':'ys_tostring({0})','ord':'yv_long(ys_ord({0}))',
                'puts':'(puts_({0}),yv_none())','eputs':'(eputs_({0}),yv_none())','argv':'argv_()',
                'exit':'(exit_(yv_l({0})),yv_none())','exec':'cg_exec({0})','unwrap':'yv_unwrap({0})','some':'{0}',
                'is_some':'yv_bool(!yv_is_none({0}))','clock_us':'yv_long(clock_us())',
                'heap_used':'yv_long(heap_used())','bytes':'bytes_of({0})','from_bytes':'from_bytes({0})',
                'trim':'ys_trim({0})','split':'ys_split({0},{1})','join':'ys_join({0},{1})',
                'index_of':'yv_long(ys_index_of({0},{1}))','chr':'ys_chr(yv_l({0}))',
                'push':'ya_push({0},{1})','tolong':'ys_tolong_opt({0})',
                'byte_at':'yv_long(ys_byte_at({0},yv_l({1})))',
                'byte_len':'yv_long(byte_len({0}))',
                'last_index_of':'yv_long(ys_last_index_of({0},{1}))',
                'tofloat':'yv_float(yv_f({0}))','is_none':'yv_bool(yv_is_none({0}))',
                'opt$test':'yv_bool(!yv_is_none({0}))','opt$val':'yv_unwrap({0})',
                'region$':'{0}','region$auto':'{0}','heap$':'{0}'}
        if name in {'ptr_addr','ptr_from'}: return self.seq(args,lambda x:x[0])
        if name=='syscall': return self.seq(args,lambda x:f'cg_syscall({len(x)},(Yv*[]){{'+','.join(x)+'})')
        if name=='print': return self.seq(args,lambda x:''.join(f'puts_(ys_tostring({v}));' for v in x)+'putchar(10);fflush(stdout);yv_none()')
        if name in direct: return self.seq(args,lambda x:direct[name].format(*x))
        return self.seq([self.expr(n['callee'])]+args,lambda x:f'cg_call({x[0]},{len(args)},(Yv*[]){{'+','.join(x[1:])+'})')

    def generate(self,tree):
        self.bindings(tree)
        def collect(node):
            if isinstance(node,dict):
                if node.get('tag')=='decl': self.types[node['name']]=node['typ']
                if node.get('tag')=='func': self.types.update(zip(node['params'],node['ptypes']))
                for child in node.values(): collect(child)
            elif isinstance(node,list):
                for child in node: collect(child)
        collect(tree)
        body=self.block(tree['stmts'],False)
        declarations='\n'.join(re.match(r'.*?\)',fn).group(0)+';' for fn in self.functions)
        globals_ = ''.join(f'static Yv *{self.variables[name]};' for name in sorted(self.globals))
        return ('/* Generated from Y; do not edit. */\n#include "runtime.h"\n'+globals_+'\n'+declarations+'\n'+'\n'.join(self.functions)+
                '\nint main(int argc,char **argv){yv_set_argv(argc,argv);CgEnv *env __attribute__((cleanup(cg_env_drop)))=cg_scope(NULL);'+self.local_declarations(tree)+body+';return 0;}\n')
