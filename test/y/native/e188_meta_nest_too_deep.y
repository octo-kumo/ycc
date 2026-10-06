// expect-error: 7:25: error: meta blocks nest deeper than 8: each level of nesting costs another compile and run of the meta generator, so this is a cost limit, not the parser's
// The cap is a COST bound, not the parser's: each level of nesting costs one
// more compile and one more run of the generator, because a nested block's text
// has to be known before the source of the block around it can be compiled.
// Nine levels is one over the limit, and the message says what the limit costs
// rather than leaving `too_deep` to fire inside a file that does not exist.
#{ #{ #{ #{ #{ #{ #{ #{ #{ #{ "x" }# }# }# }# }# }# }# }# }# }#
