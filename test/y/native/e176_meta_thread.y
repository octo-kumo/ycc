// expect-error: 2:21: error: 'spawn' cannot be used in a meta block: the generator runs in a forked child, and a thread or process primitive there is never what was meant
#{ let t = spawn { 1 }; 0 }#
