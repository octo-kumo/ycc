// scratch: the harness runs this fixture in a scratch directory (relative paths)
// std/fs.y's path helpers: the string half of a path, which every program
// that walks a tree re-implemented (the audit measured three of its own
// probes doing the same 14 lines). Nothing here touches the file system.
import fs;

// dirname/basename: POSIX shape, so a trailing slash does not count and a
// path that is only a root stays a root
print(fs.path_dirname("/a/b/c"), " ", fs.path_basename("/a/b/c"));
print(fs.path_dirname("a"), " ", fs.path_basename("a"));
print(fs.path_dirname("/"), " ", fs.path_basename("/"));
print(fs.path_dirname(""), " ", fs.path_basename(""));
print(fs.path_dirname("/a/b/"), " ", fs.path_basename("/a/b/"));
print(fs.path_dirname("a/b"), " ", fs.path_basename("a/b"));
print(fs.path_dirname("./a"), " ", fs.path_basename("./a"));

// extension/stem: a leading dot is part of the name, not an extension
print(fs.path_extension("/a/b/c.txt"), " ", fs.path_stem("/a/b/c.txt"));
print(fs.path_extension("/a/.bashrc"), " ", fs.path_stem("/a/.bashrc"));
print(fs.path_extension("noext"), " ", fs.path_stem("noext"));
print(fs.path_extension("/a/b/a.tar.gz"), " ", fs.path_stem("/a/b/a.tar.gz"));
print(fs.path_extension("a."), " ", fs.path_stem("a."));
print(fs.path_extension(".."), " ", fs.path_stem(".."));
print(fs.path_extension("/"), " ", fs.path_stem("/"));

// join: an empty side is the other, an absolute b replaces a outright, and
// otherwise exactly one "/" goes between
print(fs.path_join("a", "b"), " ", fs.path_join("a/", "b"), " ", fs.path_join("a", "/b"));
print(fs.path_join("", "b"), " ", fs.path_join("a", ""), " ", fs.path_join("", ""));
print(fs.path_join("/", "a"), " ", fs.path_join("a/b", "c/d"));
print(fs.path_join("/a/b/", "c/"), " ", fs.path_join(".", "x"));

// and they compose with the rest of fs: a real file, built from parts and
// taken apart again
let d = "ynative_t214_dir";
let f = fs.path_join(d, "sub");
print(fs.make_dirs(f), " ", fs.write_file(fs.path_join(f, "data.tar.gz"), "x"));
print(fs.is_dir(f), " ", fs.path_dirname(fs.path_join(f, "data.tar.gz")));
print(fs.path_basename(fs.path_join(f, "data.tar.gz")), " ", fs.path_extension(fs.path_join(f, "data.tar.gz")));
print(fs.path_stem(fs.path_join(f, "data.tar.gz")), " ", fs.list_dir(f)!);
print(fs.remove_all(d), " ", fs.exists(d));