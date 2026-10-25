// Recursive meta, the second acceptance case: a nested block that generates a
// NAME, joined mid-token to a token in the enclosing block's own source.
//
// `var#{ 1+1}#` is mid-token, so the nested block's call is hoisted out of the
// enclosing block (the mid-token rule, unchanged) -- and the text it produced,
// `2`, goes into the enclosing source in its place, making `var2`. The enclosing
// block then runs with `var2` bound, and its text is what the program gets: the
// generated program declares both variables and prints `var2`, which is 2.
//
// What a block's text IS, is the rendering of its own value -- the same rule the
// first acceptance case needs, where the enclosing block's value is the long 2.
// So a block whose value is a long emits `2`, NOT its own source. The literal
// form of the request -- an enclosing block that ends by NAMING the variable it
// just generated -- therefore cannot give the program that variable, because its
// text is its value, not its source; the NEAREST WORKING FORM is for the
// enclosing block to return the text the program should get, which is what the
// concatenation below does with the generated name.
#{ let var1 = 1; let var2 = 2; "let var1 = 1;\nlet var2 = 2;\nprint(var" + tostring(var#{ 1+1}#) + ");\n" }#
