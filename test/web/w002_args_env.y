// argv and the environment cross the host boundary unchanged: argv()[1]
// is the first argument after the program, and YTEST_WEB_ENV comes from the
// environment the runner was given.
import fs;
puts(argv()[1] + "\n");
region {
    let e = fs.getenv("YTEST_WEB_ENV");
    if (e != none) { puts(unwrap(e) + "\n"); };
};
