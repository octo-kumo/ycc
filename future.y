// this file contains some ideas for future.
// planned but not yet decided on how exactly i want them to look like.
// locks, semaphores, and other concurrency primitives

let thread1 = spawn {
    // thread body goes here
};

let thread2 = spawn {
    // another thread body goes here
};

join thread1;
join thread2;

let m = mutex();
lock m {
    // critical section code goes here
}

(try_lock m {
    // lock is acquired, critical section code goes here
    // if lock is not free, this is not ran
}) // the whole block returns a bool, indicating whether the lock was successfully acquired or not

let s = sem(0);
post s; // increment semaphore
wait s; // decrement semaphore, block if value is 0



// http itself is a module, but is also a global client.


let res = http.get("https://example.com");
let res = http.post("https://example.com", body);
// http.put, http.delete, http.patch, etc.

let res = http.get(url);
// res is a record
res.status        // status code, e.g. 200, 404, etc. :long
res.headers       // a map of str to str
res.size          // Content-Length if present otherwise -1 :long
res.read(n)       // partial -> [byte] only reads n bytes, returns [byte]
res.read(0)       // full -> [byte] blocks until all data is read, returns [byte]
res.text()        // full -> str blocks until all data is read, returns str

http.header("Content-Type", "application/json"); // set a header for the next request, and returns self