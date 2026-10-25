// The emitter's flat environment: past 64 entries it is indexed by name
// instead of scanned, and the index is filled in one go the first time the env
// is that wide (native.y ENV_SCAN_MAX, env_index_all). A function with more
// locals than that must still find every one of them -- the entries the sweep
// took, the ones indexed as they were defined, its parameters, a global and a
// top-level def -- and read the right values: a wrong index is a miscompile,
// not a slowdown.
let gshift = 1000;
def helper(x: long) -> long { x * 2 };
def wide(p0: long, p1: long) -> long {
    let v0 = 1;
    let v1 = 2;
    let v2 = 3;
    let v3 = 4;
    let v4 = 5;
    let v5 = 6;
    let v6 = 7;
    let v7 = 8;
    let v8 = 9;
    let v9 = 10;
    let v10 = 11;
    let v11 = 12;
    let v12 = 13;
    let v13 = 14;
    let v14 = 15;
    let v15 = 16;
    let v16 = 17;
    let v17 = 18;
    let v18 = 19;
    let v19 = 20;
    let v20 = 21;
    let v21 = 22;
    let v22 = 23;
    let v23 = 24;
    let v24 = 25;
    let v25 = 26;
    let v26 = 27;
    let v27 = 28;
    let v28 = 29;
    let v29 = 30;
    let v30 = 31;
    let v31 = 32;
    let v32 = 33;
    let v33 = 34;
    let v34 = 35;
    let v35 = 36;
    let v36 = 37;
    let v37 = 38;
    let v38 = 39;
    let v39 = 40;
    let v40 = 41;
    let v41 = 42;
    let v42 = 43;
    let v43 = 44;
    let v44 = 45;
    let v45 = 46;
    let v46 = 47;
    let v47 = 48;
    let v48 = 49;
    let v49 = 50;
    let v50 = 51;
    let v51 = 52;
    let v52 = 53;
    let v53 = 54;
    let v54 = 55;
    let v55 = 56;
    let v56 = 57;
    let v57 = 58;
    let v58 = 59;
    let v59 = 60;
    let v60 = 61;
    let v61 = 62;
    let v62 = 63;
    let v63 = 64;
    let v64 = 65;
    let v65 = 66;
    let v66 = 67;
    let v67 = 68;
    let v68 = 69;
    let v69 = 70;
    let v70 = 71;
    let v71 = 72;
    let v72 = 73;
    let v73 = 74;
    let v74 = 75;
    let v75 = 76;
    let v76 = 77;
    let v77 = 78;
    let v78 = 79;
    let v79 = 80;
    v0 + v1 + v2 + v3 + v4 + v5 + v6 + v7 + v8 + v9 + v10 + v11 + v12 + v13 + v14 + v15 + v16 + v17 + v18 + v19 + v20 + v21 + v22 + v23 + v24 + v25 + v26 + v27 + v28 + v29 + v30 + v31 + v32 + v33 + v34 + v35 + v36 + v37 + v38 + v39 + v40 + v41 + v42 + v43 + v44 + v45 + v46 + v47 + v48 + v49 + v50 + v51 + v52 + v53 + v54 + v55 + v56 + v57 + v58 + v59 + v60 + v61 + v62 + v63 + v64 + v65 + v66 + v67 + v68 + v69 + v70 + v71 + v72 + v73 + v74 + v75 + v76 + v77 + v78 + v79 + gshift + helper(p0) + p1
};
print(wide(7, 9));
// and again, so the index is reused rather than rebuilt
print(wide(1, 1));
