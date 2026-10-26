// flags: --ob=full --ob-seed=3
// The child inherits the decrypted-page state; the parent reaps it.
let pid = fork(def () -> long { 7 });
if (pid > 0) {
    wait_pid(pid);
    print("parent reaped");
};
