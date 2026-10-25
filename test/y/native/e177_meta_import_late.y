// expect-error: 2:19: error: an import inside a meta block must come first in the block
#{ let a = 1; import fs; a }#
