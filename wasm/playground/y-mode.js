// CodeMirror 5 mode for the Y language.
// Keywords, operators, and literal styles mirror ycc's lexer (ycc/lexer.y).
(function (mod) {
  if (typeof exports === "object" && typeof module === "object") mod(require("../../lib/codemirror"));
  else if (typeof define === "function" && define.amd) define(["../../lib/codemirror"], mod);
  else mod(CodeMirror);
})(function (CodeMirror) {
  "use strict";

  const KEYWORDS = new Set([
    "let", "const", "def", "if", "else", "while", "for", "foreach",
    "in", "return", "true", "false", "null", "import", "export", "from",
  ]);
  const TYPES = new Set(["long", "str", "bool", "float"]);
  const BUILTINS = new Set([
    "print", "puts", "len", "substr", "push", "tostring", "tonum", "typeof",
    "range", "index_of", "arr_index_of", "last_index_of", "ord", "chr",
    "join", "split", "trim", "map_set", "map_get",
  ]);

  CodeMirror.defineMode("y", function () {
    function tokenBase(stream, state) {
      const ch = stream.peek();

      // whitespace
      if (/\s/.test(ch)) { stream.eatSpace(); return null; }

      // line comment
      if (ch === "/" && stream.match("//")) { stream.skipToEnd(); return "comment"; }
      // block comment
      if (ch === "/" && stream.match("/*")) { state.inBlock = true; return "comment"; }
      if (state.inBlock) {
        while (!stream.eol()) {
          if (stream.match("*/")) { state.inBlock = false; break; }
          stream.next();
        }
        return "comment";
      }

      // string
      if (ch === '"') {
        stream.next();
        let escaped = false;
        while (!stream.eol()) {
          const c = stream.next();
          if (escaped) { escaped = false; continue; }
          if (c === "\\") { escaped = true; continue; }
          if (c === '"') break;
        }
        return "string";
      }

      // number
      if (/[0-9]/.test(ch) || (ch === "." && /[0-9]/.test(stream.string[stream.pos + 1] || ""))) {
        stream.match(/^[0-9]*\.?[0-9]+/);
        return "number";
      }

      // identifier / keyword
      if (/[A-Za-z_]/.test(ch)) {
        stream.match(/^[A-Za-z_0-9]*/);
        const word = stream.current();
        if (KEYWORDS.has(word)) return "keyword";
        if (TYPES.has(word)) return "type";
        if (BUILTINS.has(word)) return "builtin";
        // function definition name or call
        if (stream.peek() === "(") return "def";
        return "variable";
      }

      // operators / punctuation
      if (stream.match("->") || stream.match("..") || stream.match("==") ||
          stream.match("!=") || stream.match("<=") || stream.match(">=") ||
          stream.match("&&") || stream.match("||") || stream.match("::")) {
        return "operator";
      }
      if (/[+\-*/%=<>!]/.test(ch)) { stream.next(); return "operator"; }
      if (/[{}()\[\],;:.]/.test(ch)) { stream.next(); return "punctuation"; }

      stream.next();
      return null;
    }

    return {
      startState: () => ({ inBlock: false }),
      token: tokenBase,
      lineComment: "//",
      blockCommentStart: "/*",
      blockCommentEnd: "*/",
    };
  });

  CodeMirror.defineMIME("text/x-y", "y");
});
