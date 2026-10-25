// fs.getenv on Windows reads the process's own environment block; pe-gate sets
// YTEST_ENV and checks the answers.
import fs;
print(fs.getenv("YTEST_ENV"));
print(fs.getenv("YTEST_ENV_NOT_SET"));
print(fs.getenv("YTEST_ENV_UTF"));
print(fs.getenv("YTEST_ENV_EMPTY"));
