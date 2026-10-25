// expect-error: 2:1: error: non-exhaustive match on long (add a '_' arm; value patterns match only the values they name and cover no type)
match 1 { 0 => 0 };
