// scene.y -- the built-in scenes, shared by the driver and the property check.
//
// ===========================================================================
// WHY THIS IS ITS OWN MODULE
//
// sandfall.y builds a scene to draw it and props.y builds the same scenes to
// check them.  If each had its own copy, the check would be testing a scene
// builder that is not the one the program runs, and a divergence between the
// two would be invisible.  So there is exactly one copy of every scene, here,
// and both modules call it.
//
// Every scene is rectangles and straight lines of ARITHMETIC -- no clock, no
// unseeded generator -- so its cell counts can be worked out by hand.  That
// matters: props.y asserts the conserved totals against literals of its own,
// not against what this module happened to produce, because a conservation
// check that reads its expected value from the code under test is 0 == 0
// wearing a conservation costume (day09 in this campaign).
//
// The one scene that uses --seed is `terrain`, and props.y C7 asserts that two
// different seeds really do give two different grids -- otherwise "same seed,
// same picture" would be true because the seed is ignored.

import grid;

// build(name, w, h, seed) -> str -- put the scene on a cleared grid.  "" when
// it worked; otherwise the message to print before exiting 1.
//
// Every failure here is a MESSAGE and never a trap: a scene that does not fit
// the requested grid is diagnosed by name, before a single index is written,
// so a runtime error can never reach stdout and corrupt EXPECTED (in Y a trap
// prints on stdout -- ORCHESTRATOR.md 2.6).
def build(name: str, w: long, h: long, seed: long) -> str {
    grid.clear(w, h);
    grid.srand(seed);

    if (name == "empty") { return "" };

    if (name == "basin") {
        // A stone floor, a sand heap in the middle, a water pool on the left
        // and a burning oil slick on the right.  At w x h:
        //   floor    w x 3 stone
        //   heap     6 rows of 1,3,5,7,9,11 sand = 36
        //   pool     (w/8) x (w/4) water, 4 rows tall
        //   slick    (w/4) x 2 oil, and one fire on top of it
        let fy = h - 3;
        if (fy < 8) { return "--scene basin needs a grid at least 11 rows tall" };
        if (!grid.rect_logical(0, fy, w - 1, h - 1, grid.M_STONE)) {
            return "--scene basin does not fit the grid"
        };
        let r = 0;
        while (r < 6) {
            let half = 0 - r;
            while (half <= r) {
                if (!grid.put_logical(w / 2 + half, fy - 6 + r, grid.M_SAND)) {
                    return "--scene basin does not fit the grid"
                };
                half = half + 1
            };
            r = r + 1
        };
        let wl = w / 8;
        let ww = w / 4;
        if (ww < 2) { return "--scene basin needs a grid at least 32 wide" };
        if (!grid.rect_logical(wl, fy - 4, wl + ww - 1, fy - 1, grid.M_WATER)) {
            return "--scene basin does not fit the grid"
        };
        let ow = w / 4;
        let ol = w - 4 - ow;
        if (!grid.rect_logical(ol, fy - 2, ol + ow - 1, fy - 1, grid.M_OIL)) {
            return "--scene basin does not fit the grid"
        };
        if (!grid.put_logical(ol, fy - 3, grid.M_FIRE)) {
            return "--scene basin does not fit the grid"
        };
        return ""
    };

    if (name == "drip") {
        // One stone column with a stream of water above it: the clearest
        // demonstration that water falls, spreads sideways and does not pile.
        let cx = w / 2;
        let fy = h - 2;
        if (fy < 7) { return "--scene drip needs a grid at least 9 rows tall" };
        if (!grid.rect_logical(0, fy, w - 1, h - 1, grid.M_STONE)) {
            return "--scene drip does not fit the grid"
        };
        let top = h / 3;
        if (!grid.rect_logical(cx - 1, top, cx + 1, fy - 1, grid.M_STONE)) {
            return "--scene drip does not fit the grid"
        };
        let y = 0;
        while (y < top) {
            if (!grid.put_logical(cx, y, grid.M_WATER)) {
                return "--scene drip does not fit the grid"
            };
            y = y + 1
        };
        return ""
    };

    if (name == "firestorm") {
        // A deep pool of oil with a fire in the middle of it and a sand bank to
        // the right: the fire eats the oil, the smoke rises past the bank, and
        // the fire stops when it runs out of fuel.
        let fy = h - 3;
        if (fy < 12) { return "--scene firestorm needs a grid at least 15 rows tall" };
        if (!grid.rect_logical(0, fy, w - 1, h - 1, grid.M_STONE)) {
            return "--scene firestorm does not fit the grid"
        };
        let ox = w / 6;
        let ow = w - 2 * (w / 6);
        if (ow < 4) { return "--scene firestorm needs a grid at least 24 wide" };
        if (!grid.rect_logical(ox, fy - 6, ox + ow - 1, fy - 1, grid.M_OIL)) {
            return "--scene firestorm does not fit the grid"
        };
        if (!grid.rect_logical(ox + ow, fy - 9, w - 1, fy - 1, grid.M_SAND)) {
            return "--scene firestorm does not fit the grid"
        };
        if (!grid.put_logical(ox + ow / 2, fy - 7, grid.M_FIRE)) {
            return "--scene firestorm does not fit the grid"
        };
        return ""
    };

    if (name == "terrain") {
        // The seeded scene: a stone floor, a ragged stone cavern and a seeded
        // shower of sand and water above it.
        let fy = h - 2;
        if (fy < 10) { return "--scene terrain needs a grid at least 12 rows tall" };
        if (!grid.rect_logical(0, fy, w - 1, h - 1, grid.M_STONE)) {
            return "--scene terrain does not fit the grid"
        };
        let x = 0;
        while (x < w) {
            let d = grid.rnd_below(4);
            let hh = fy - 2 - d;
            if (hh > 0) {
                if (!grid.rect_logical(x, hh, x, fy - 1, grid.M_STONE)) {
                    return "--scene terrain does not fit the grid"
                }
            };
            x = x + 1
        };
        let k = 0;
        let n = (w * (h / 2)) / 10;
        while (k < n) {
            let px = grid.rnd_below(w);
            let py = grid.rnd_below(h / 2);
            let m = grid.M_SAND;
            if (grid.rnd_below(2) == 0) { m = grid.M_WATER };
            grid.put_logical(px, py, m);
            k = k + 1
        };
        return ""
    };

    "unknown scene '" + name + "'; expected " + scene_names()
};

def scene_names() -> str { "basin | terrain | drip | firestorm | empty" };

def next_scene(c: str) -> str {
    if (c == "basin") { return "drip" };
    if (c == "drip") { return "firestorm" };
    if (c == "firestorm") { return "terrain" };
    if (c == "terrain") { return "basin" };
    "basin"
};

// The default scene, named in one place so props.y and sandfall.y cannot
// disagree about it.
const DEFAULT_SCENE = "basin";