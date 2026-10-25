// Types have k; containers describe their immediate child types. TRef can
// form cycles, so callers choose whether to descend through its to field.
const TYPE_SHAPES = [
    "TPrim",
    "TOf of:Type",
    "TFix n:long of:Type",
    "TMap key:Type of:Type",
    "TRec fields:[Field]",
    "TFunc args:[Type] ret:Type",
    "TName name:str",
    "TList ts:[Type]",
    "TPat names:[str]",
    "TPtr to:Type",
    "TInt w:long sg:bool be:bool",
    "TPack fields:[Field] bk:long",
    "TRef name:str tmp:str to:Type",
    "TInfer rets:[RetNote]",
    "TFree free:bool",
    "TPend self:bool used:bool",
    "Err",
];
export { TYPE_SHAPES };
