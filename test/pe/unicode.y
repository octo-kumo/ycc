// Non-ASCII names on Windows: a path is UTF-8 in the program and UTF-16 in the
// file system, so a name outside ASCII (two, three and four bytes in UTF-8, the
// last a surrogate pair in UTF-16) has to make the round trip through create,
// list, read, chdir, cwd and remove. Its output is the same on a system that is
// UTF-8 throughout (a PE is compared with unicode.expected, an ELF with the same).
import fs;
let dir = "dir_é_日本";
let name = "𝄞_ü.txt";
print(fs.make_dir(dir));
print(fs.write_file(dir + "/" + name, "tune\n"));
print(fs.list_dir(dir)!);
print(fs.read_file(dir + "/" + name)!);
print(fs.exists(dir + "/" + name), " ", fs.is_dir(dir), " ", fs.file_size(dir + "/" + name)!);
print(fs.chdir(dir));
print(fs.cwd().ends_with("dir_é_日本"));
print(fs.read_file(name)!);
print(fs.chdir(".."));
print(fs.rename(dir + "/" + name, dir + "/ß.txt"));
print(fs.list_dir(dir)!);
print(fs.remove_file(dir + "/ß.txt"));
print(fs.remove_dir(dir));
print(fs.exists(dir));
