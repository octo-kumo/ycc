// scratch: the harness runs this fixture in a scratch directory (relative paths)
// fs.remove_all decided "directory" with stat, which follows a symlink, so
// on a link to a directory it walked and deleted the *target's* contents --
// a path the caller never named -- and then answered false, because rmdir on
// a symlink fails. rm -rf unlinks the link and leaves the target, and so
// does remove_all now: lstat decides what a path is itself. The functions
// that are *about* what a path names still follow a link, which is what they
// are for, and the last block pins that too.
import fs;
// symlinkat is 266, and its target comes FIRST -- unlike every other *at
// syscall here, where the dirfd leads.
def link_to(target: str, link: str) -> bool { syscall(266, target, -100, link) == 0 };
let base = fs.cwd() + "/ytest_t177_" + tostring(syscall(39));
fs.remove_all(base);
print("tree ", fs.make_dirs(base + "/target/deep"), " ",
      fs.write_file(base + "/target/keep.txt", "keep\n"), " ",
      fs.write_file(base + "/target/deep/inner.txt", "inner\n"), " ",
      fs.write_file(base + "/plain.txt", "plain\n"));

// A link to a directory: unlinked, with the target and all in it untouched.
print("link ", link_to(base + "/target", base + "/link"));
print("the link names a dir ", fs.is_dir(base + "/link"), " ",
      fs.is_file(base + "/link"), " ", fs.exists(base + "/link"));
print("remove_all(link) ", fs.remove_all(base + "/link"));
print("link gone ", !fs.exists(base + "/link"), " target kept ",
      fs.read_file(base + "/target/keep.txt"), " ",
      fs.read_file(base + "/target/deep/inner.txt"));

// A link to a file: the file stays, the link goes.
print("file link ", link_to(base + "/plain.txt", base + "/flink"), " ",
      fs.remove_all(base + "/flink"), " ", !fs.exists(base + "/flink"), " ",
      fs.read_file(base + "/plain.txt"));

// A link inside a tree removed wholesale goes with the tree, and the
// directory it names -- outside that tree -- keeps everything. A dangling
// link (its target is not there) is unlinked all the same.
print("inside ", fs.make_dirs(base + "/tree"), " ",
      link_to(base + "/target", base + "/tree/out"), " ",
      link_to(base + "/nope", base + "/tree/dangling"), " ",
      fs.write_file(base + "/tree/x.txt", "x\n"));
print("remove_all(tree) ", fs.remove_all(base + "/tree"), " ", !fs.exists(base + "/tree"),
      " target kept ", fs.list_dir(base + "/target")!);
print("a dangling link ", link_to(base + "/nope", base + "/dangle"), " ",
      fs.remove_all(base + "/dangle"), " ", !fs.exists(base + "/dangle"));

// An ordinary tree still goes; a path that is not there still says so.
print("remove_all(target) ", fs.remove_all(base + "/target"), " ",
      !fs.exists(base + "/target"));
print("remove_all(nothing) ", fs.remove_all(base + "/nothing"), " ",
      fs.remove_all(base + "/plain.txt"), " ", !fs.exists(base + "/plain.txt"));

// A trailing slash is a different path: POSIX resolution makes "link/" name
// the target's contents, and rm -rf takes them there too, leaving the link
// and the emptied directory behind. remove_all matches that and adds the
// truth rm -f swallows: the directory it named is still there, so it says
// false.
print("slash link ", fs.make_dirs(base + "/dir/inner"), " ",
      fs.write_file(base + "/dir/inner/v.txt", "v\n"), " ",
      link_to(base + "/dir", base + "/slink"));
print("remove_all(slink/) ", fs.remove_all(base + "/slink/"), " ",
      fs.list_dir(base + "/dir")!, " ", fs.exists(base + "/slink"), " ",
      fs.list_dir(base)!);

// What the rest of the module does with a link, unchanged: stat follows one,
// so it is a directory or a file by what it names, list_dir lists it and a
// read reads it; rename moves the link itself (rename never follows its
// last component); copy_file reads through a link and writes through one at
// `to`, as cp does; remove_file unlinks it and remove_dir refuses it.
print("setup ", fs.make_dirs(base + "/dir2"), " ",
      fs.write_file(base + "/dir2/in.txt", "in\n"), " ",
      fs.write_file(base + "/src.txt", "src\n"), " ",
      fs.write_file(base + "/dst.txt", "dst\n"), " ",
      link_to(base + "/dir2", base + "/dlink"), " ",
      link_to(base + "/dst.txt", base + "/wlink"));
print("it names ", fs.is_dir(base + "/dlink"), " ",
      fs.list_dir(base + "/dlink")!, " ",
      fs.read_file(base + "/wlink"), " ",
      fs.file_size(base + "/wlink")!);
print("rename moves the link ", fs.rename(base + "/dlink", base + "/moved"), " ",
      !fs.exists(base + "/dlink"), " ", fs.is_dir(base + "/moved"), " ",
      fs.list_dir(base + "/dir2")!);
print("copy_file writes through ", fs.copy_file(base + "/src.txt", base + "/wlink"),
      " ", fs.read_file(base + "/dst.txt"), " ", fs.exists(base + "/wlink"));
print("remove_file unlinks ", fs.remove_file(base + "/moved"), " ",
      fs.list_dir(base + "/dir2")!, " ", fs.remove_dir(base + "/wlink"), " ",
      fs.list_dir(base)!);

print("cleanup ", fs.remove_all(base), " ", !fs.exists(base));