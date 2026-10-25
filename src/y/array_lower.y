// Array methods reuse ordinary values, places, calls and control flow.
#{
    import quote from "./quote_codegen.y";
    let out = "type ArrayLowerCtx = { prefix: str, line: long, col: long, obj: Node, args: [Node], arr: Type, ft: Type, result: Type, elem: Type };\n";
    let dispatch = "def array_lower(key: str, nargs: long, q: ArrayLowerCtx) -> Node {\n";
    let a = quote.mq_var("arr");
    let i = quote.mq_var("i");
    let el = quote.mq_var("el");
    let result = quote.mq_var("out");
    let fn = quote.mq_var("fn");
    let zero = quote.mq_leaf("num", "0");
    let one = quote.mq_leaf("num", "1");
    let stop = quote.mq_leaf("kw_break", "");
    let empty = quote.mq_node("array", ", elems: []");
    let no_type = "normtype({ k: K.tnone })";
    for n in 0..3 {
        let args: [str] = [];
        if (n >= 1) { args += el; };
        if (n >= 2) { args += i; };
        let call = quote.mq_call(fn, args);
        let reducer_args: [str] = [];
        if (n >= 1) { reducer_args += result; };
        if (n >= 2) { reducer_args += el; };
        let methods: [{ name: str, init: [str], body: [str], result: str, callback: bool }] = [
            { name: "foreach",
                init: [],
                body: [call], result: quote.mq_node("void"), callback: true },
            { name: "map",
                init: [quote.mq_decl("out", "q.result", empty)],
                body: [quote.mq_op("+", result, call)],
                result: result, callback: true },
            { name: "filter",
                init: [quote.mq_decl("out", "q.result", empty)],
                body: [quote.mq_if(call, [quote.mq_op("+", result, el)])],
                result: result, callback: true },
            { name: "all",
                init: [quote.mq_decl("out", no_type, quote.mq_leaf("bool", "true"))],
                body: [quote.mq_if(quote.mq_un("!", call), [quote.mq_set("out", quote.mq_leaf("bool", "false")), stop])],
                result: result, callback: true },
            { name: "some",
                init: [quote.mq_decl("out", no_type, quote.mq_leaf("bool", "false"))],
                body: [quote.mq_if(call, [quote.mq_set("out", quote.mq_leaf("bool", "true")), stop])],
                result: result, callback: true },
            { name: "find",
                init: [quote.mq_decl("out", "q.result", quote.mq_leaf("id", "none"))],
                body: [quote.mq_if(call, [quote.mq_set("out", quote.mq_call(quote.mq_leaf("id", "some"), [el])), stop])],
                result: result, callback: true },
            { name: "reduce",
                init: [quote.mq_decl("out", "q.result", "q.args[1]")],
                body: [quote.mq_set("out", quote.mq_call(fn, reducer_args))],
                result: result, callback: true },
            { name: "flat",
                init: [quote.mq_decl("out", "q.result", empty)],
                body: [quote.mq_op("+", result, el)],
                result: result, callback: false },
            { name: "index",
                init: [quote.mq_decl("value", "q.elem", "q.args[0]"), quote.mq_decl("out", no_type, quote.mq_leaf("num", "-1"))],
                body: [quote.mq_if(quote.mq_bin("==", el, quote.mq_var("value")), [quote.mq_set("out", i), stop])],
                result: result, callback: false },
        ];
        foreach (method in methods) {
            if (n == 0 || !(method.name in ["flat", "index"])) {
                let nodes = [quote.mq_decl("arr", "q.arr", "q.obj")];
                if (method.callback) { nodes += quote.mq_decl("fn", "q.ft", quote.mq_block(["q.args[0]"])); };
                nodes += method.init;
                nodes += quote.mq_decl("i", no_type, zero);
                nodes += quote.mq_loop(quote.mq_bin("<", i, quote.mq_call(quote.mq_leaf("id", "len"), [a])),
                    [quote.mq_decl("el", "q.elem", quote.mq_index(a, i))] + method.body + [quote.mq_op("+", i, one)]);
                nodes += method.result;
                let name = "array_lower_" + method.name + tostring(n);
                out += "def " + name + "(q: ArrayLowerCtx) -> Node { " + quote.mq_block(nodes) + " };\n";
                dispatch += "if (key == \"" + method.name + "\"" + (method.name in ["flat", "index"] ? "" : (n == 2 ? " && nargs >= " : " && nargs == ") + tostring(n)) + ") { return " + name + "(q); };\n";
            };
        };
    };
    let j = quote.mq_var("j");
    let value = quote.mq_var("value");
    let keyval = quote.mq_var("key");
    foreach (key in ["sort", "sorted"]) {
        for n in 0..3 {
            let comparator_args: [str] = [];
            if (n >= 1) { comparator_args += value; };
            if (n >= 2) { comparator_args += keyval; };
            let name = "array_lower_" + key + tostring(n);
            let obj = key == "sort" ? "q.obj" : quote.mq_node("slice", ", arr: q.obj, lo: " + quote.mq_node("void") + ", hi: " + quote.mq_node("void"));
            let nodes = [quote.mq_decl("arr", "q.arr", obj), quote.mq_decl("fn", "q.ft", quote.mq_block(["q.args[0]"])), quote.mq_decl("i", no_type, one),
                quote.mq_loop(quote.mq_bin("<", i, quote.mq_call(quote.mq_leaf("id", "len"), [a])), [
                    quote.mq_decl("key", "q.elem", quote.mq_index(a, i)), quote.mq_decl("j", no_type, quote.mq_bin("-", i, one)),
                    quote.mq_loop(quote.mq_bin(">=", j, zero), [quote.mq_decl("value", "q.elem", quote.mq_index(a, j)),
                        quote.mq_if(quote.mq_bin("<=", quote.mq_call(fn, comparator_args), zero), [stop]),
                        quote.mq_put(a, quote.mq_bin("+", j, one), value), quote.mq_op("-", j, one)]),
                    quote.mq_put(a, quote.mq_bin("+", j, one), keyval), quote.mq_op("+", i, one)]), a];
            out += "def " + name + "(q: ArrayLowerCtx) -> Node { " + quote.mq_block(nodes) + " };\n";
            dispatch += "if (key == \"" + key + "\"" + (n == 2 ? " && nargs >= " : " && nargs == ") + tostring(n) + ") { return " + name + "(q); };\n";
        };
    };
    let header = "normtype({ k: K.tptr, to: normtype({ k: K.tlong }) })";
    foreach (key in ["pop", "shift", "remove"]) {
        for n in 1..(key == "remove" ? 3 : 2) {
            let idx = key == "pop" ? quote.mq_bin("-", quote.mq_call(quote.mq_leaf("id", "len"), [a]), one) : key == "shift" ? zero : "q.args[0]";
            let count = n == 2 ? "q.args[1]" : one;
            let limit = quote.mq_call(quote.mq_leaf("id", "len"), [a]);
            let ci = quote.mq_var("count");
            let ix = quote.mq_var("idx");
            let end = quote.mq_var("end");
            let nodes = [quote.mq_decl("arr", "q.arr", "q.obj"), quote.mq_decl("idx", no_type, idx), quote.mq_decl("count", no_type, count)];
            if (n == 2) {
                let invalid = quote.mq_bin("||", quote.mq_bin("||", quote.mq_bin("<", ix, zero), quote.mq_bin("<", ci, zero)),
                    quote.mq_bin("||", quote.mq_bin(">", ix, limit), quote.mq_bin(">", ci, quote.mq_bin("-", limit, ix))));
                nodes += quote.mq_if(invalid, [quote.mq_index(a, quote.mq_leaf("num", "-1"))]);
            };
            let removed = n == 2 ? quote.mq_node("slice", ", arr: " + a + ", lo: " + ix + ", hi: " + quote.mq_bin("+", ix, ci)) : quote.mq_index(a, ix);
            nodes += quote.mq_decl("out", "q.result", removed);
            nodes += quote.mq_decl("end", no_type, quote.mq_bin("-", limit, ci));
            if (key != "pop") {
                nodes += quote.mq_decl("i", no_type, ix);
                nodes += quote.mq_loop(quote.mq_bin("<", i, end), [quote.mq_put(a, i, quote.mq_index(a, quote.mq_bin("+", i, ci))), quote.mq_op("+", i, one)]);
            };
            nodes += quote.mq_decl("header", header, quote.mq_node("narrow", ", e: " + a + ", typ: " + header));
            nodes += quote.mq_node("store", ", p: " + quote.mq_var("header") + ", v: " + end);
            nodes += result;
            let name = "array_lower_" + key + tostring(n);
            out += "def " + name + "(q: ArrayLowerCtx) -> Node { " + quote.mq_block(nodes) + " };\n";
            dispatch += "if (key == \"" + key + "\"" + (key == "remove" ? " && len(q.args) == " + tostring(n) : "") + ") { return " + name + "(q); };\n";
        };
    };
    foreach (key in ["push", "unshift"]) {
        let call = quote.mq_call(quote.mq_leaf("id", key == "push" ? "push" : "prepend"), ["q.obj", "q.args[0]"]);
        out += "def array_lower_" + key + "(q: ArrayLowerCtx) -> Node { " + quote.mq_call(quote.mq_leaf("id", "len"), [call]) + " };\n";
        dispatch += "if (key == \"" + key + "\") { return array_lower_" + key + "(q); };\n";
    };
    out + dispatch + "eputs(\"internal error: no lowering for array.\" + key); exit(1); q.obj };\n"
}#
