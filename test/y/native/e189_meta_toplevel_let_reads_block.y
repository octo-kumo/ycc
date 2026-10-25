// expect-error: 14:13: error: undefined variable 'var2'
// expect-error: error: the meta generator did not compile
// A top-level `let` may not READ a name a block generates. The rounds that
// resolve a nested block leave a stand-in where the enclosing block's call goes
// (meta.y sg_top_close), and a stand-in declares nothing -- so the reduction
// drops the top-level statements that are not declarations, which is why
// `print(var2);` after such a block is fine and this `let` is not.
//
// The rule is the pass's own "keep top-level let initializers pure", one step
// sharper: pure is not enough, the initializer must not depend on what a block
// generates. Both names come from the same block: it generates `var2`, and this
// let reads it.
#{ let var2 = 2; "let var2 = 2;\n" }#
let alias = var2;
print(alias);
