// expect-error: error: cannot embed 'no_such_file.txt'
embed DATA from "no_such_file.txt";
print(DATA);
