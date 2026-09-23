// shell.y — a simple interactive shell written in the y language
// Features: built-in commands, argument parsing, infix→RPN calculator
// Run: ./compiler --compile examples/shell.y -o ysh && ./ysh

// ── helpers ──────────────────────────────────────────────────────────────

def banner() {
    puts("ysh 0.1 — type 'help' for commands\n");
};

def show_help() {
    puts("commands:\n");
    puts("  help              show this help\n");
    puts("  echo <args...>    print arguments\n");
    puts("  calc <expr...>    calculator: infix math -> RPN -> stack eval\n");
    puts("                    e.g. calc 3 + 4 * 2  ->  11\n");
    puts("                    supports + - * / % ( )\n");
    puts("  rev <args...>     reverse argument order\n");
    puts("  count <args...>   count arguments\n");
    puts("  seq <n>           print 1..n\n");
    puts("  exit              quit the shell\n");
    puts("  <anything else>   run as system command\n");
};

// ── operator precedence for shunting-yard ────────────────────────────────

def op_prec(op: str) -> long {
    if (op == "+" || op == "-") {
        1
    } else if (op == "*" || op == "/" || op == "%") {
        2
    } else {
        0
    }
};

def is_op(tok: str) -> bool {
    tok == "+" || tok == "-" || tok == "*" || tok == "/" || tok == "%"
};

// ── shunting-yard: infix tokens -> RPN tokens ────────────────────────────
// tokens are space-separated (from split), so "3 + 4 * 2" -> ["3","+","4","*","2"]

def shunting_yard(tokens: [str]) -> [str] {
    let n = len(tokens);
    let out = ["", "", "", "", "", "", "", "", "", "",
               "", "", "", "", "", "", "", "", "", "",
               "", "", "", "", "", "", "", "", "", "",
               "", "", "", "", "", "", "", "", "", "",
               "", "", "", "", "", "", "", "", "", ""];
    let oi = 0;
    let ops = ["", "", "", "", "", "", "", "", "", "",
               "", "", "", "", "", "", "", "", "", "",
               "", "", "", "", "", "", "", "", "", ""];
    let si = 0;
    let i = 0;
    while (i < n) {
        let tok = tokens[i];
        if (is_op(tok)) {
            while (si > 0 && ops[si - 1] != "(" && op_prec(ops[si - 1]) >= op_prec(tok)) {
                si = si - 1;
                out[oi] = ops[si];
                oi = oi + 1;
            };
            ops[si] = tok;
            si = si + 1;
        } else if (tok == "(") {
            ops[si] = tok;
            si = si + 1;
        } else if (tok == ")") {
            while (si > 0 && ops[si - 1] != "(") {
                si = si - 1;
                out[oi] = ops[si];
                oi = oi + 1;
            };
            if (si > 0) {
                si = si - 1;
            };
        } else {
            out[oi] = tok;
            oi = oi + 1;
        };
        i = i + 1;
    };
    while (si > 0) {
        si = si - 1;
        out[oi] = ops[si];
        oi = oi + 1;
    };
    out[0:oi]
};

// ── RPN evaluator: stack VM ──────────────────────────────────────────────

def rpn_eval(rpn: [str]) -> long {
    let n = len(rpn);
    let stack = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    let sp = 0;
    let i = 0;
    while (i < n) {
        let tok = rpn[i];
        if (tok == "+") {
            let b = stack[sp - 1];
            let a = stack[sp - 2];
            sp = sp - 1;
            stack[sp - 1] = a + b;
        } else if (tok == "-") {
            let b = stack[sp - 1];
            let a = stack[sp - 2];
            sp = sp - 1;
            stack[sp - 1] = a - b;
        } else if (tok == "*") {
            let b = stack[sp - 1];
            let a = stack[sp - 2];
            sp = sp - 1;
            stack[sp - 1] = a * b;
        } else if (tok == "/") {
            let b = stack[sp - 1];
            let a = stack[sp - 2];
            sp = sp - 1;
            stack[sp - 1] = a / b;
        } else if (tok == "%") {
            let b = stack[sp - 1];
            let a = stack[sp - 2];
            sp = sp - 1;
            stack[sp - 1] = a % b;
        } else {
            stack[sp] = tonum(tok);
            sp = sp + 1;
        };
        i = i + 1;
    };
    stack[0]
};

// ── full calc pipeline: infix string -> split -> shunting-yard -> RPN eval ──

def calc(expr: str) -> long {
    let tokens = split(expr, " ");
    let rpn = shunting_yard(tokens);
    rpn_eval(rpn)
};

// ── command handlers ─────────────────────────────────────────────────────

def cmd_echo(args: [str]) {
    let n = len(args);
    let i = 1;
    let out = "";
    while (i < n) {
        if (i > 1) {
            out = out + " ";
        };
        out = out + args[i];
        i = i + 1;
    };
    puts(out + "\n");
};

def cmd_calc(args: [str]) {
    let n = len(args);
    let i = 1;
    let expr = "";
    while (i < n) {
        if (i > 1) {
            expr = expr + " ";
        };
        expr = expr + args[i];
        i = i + 1;
    };
    let result = calc(expr);
    puts(tostring(result) + "\n");
};

def cmd_rev(args: [str]) {
    let n = len(args);
    let i = n - 1;
    let out = "";
    while (i >= 1) {
        if (i < n - 1) {
            out = out + " ";
        };
        out = out + args[i];
        i = i - 1;
    };
    puts(out + "\n");
};

def cmd_count(args: [str]) {
    puts(tostring(len(args) - 1) + "\n");
};

def cmd_seq(args: [str]) {
    if (len(args) < 2) {
        puts("usage: seq <n>\n");
    } else {
        let n = tonum(args[1]);
        let i = 1;
        while (i <= n) {
            puts(tostring(i) + "\n");
            i = i + 1;
        };
    };
};

// ── main dispatch ────────────────────────────────────────────────────────

def dispatch(line: str) -> long {
    let trimmed = trim(line);
    if (len(trimmed) == 0) {
        0
    } else {
        let tokens = split(trimmed, " ");
        let cmd = tokens[0];
        if (cmd == "exit") {
            1
        } else if (cmd == "quit") {
            1
        } else if (cmd == "help") {
            show_help();
            0
        } else if (cmd == "echo") {
            cmd_echo(tokens);
            0
        } else if (cmd == "calc") {
            cmd_calc(tokens);
            0
        } else if (cmd == "rev") {
            cmd_rev(tokens);
            0
        } else if (cmd == "count") {
            cmd_count(tokens);
            0
        } else if (cmd == "seq") {
            cmd_seq(tokens);
            0
        } else {
            let code = exec(trimmed);
            if (code != 0) {
                puts("exit code: " + tostring(code) + "\n");
            };
            0
        }
    }
};

// ── REPL ─────────────────────────────────────────────────────────────────

banner();
let running = true;
while (running) {
    puts("y> ");
    let line = readline();
    if (line == null) {
        puts("\n");
        running = false;
    } else {
        // unwrap(): readline() is typed str?, and the native checker is
        // flow-insensitive, so the `== null` guard above does not narrow
        // it. The VM treats unwrap() as the identity on a non-null value,
        // so one spelling works on every engine.
        let result = dispatch(unwrap(line));
        if (result == 1) {
            running = false;
        };
    };
};
