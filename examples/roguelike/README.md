# `roguelike` — a turn-based roguelike in your terminal

Rooms and corridors on a seeded LCG, a symmetric-permissive field of view with a
shadow you can see the edge of, and a turn loop with bumping, doors, monsters,
hit points, a pack of eight slots and stairs that go down. No arguments gives you
the dungeon in the alt screen and the arrow keys.

```
      Y 1/3 T4 HP██████░░ 15/20 hit2 gold foes15 seen11%     hjkl yubn move  , grab  1-8 us
                 :          r        b
          r    #,,
               ,,>  ,
                ,,  :
               #,, !#
              ###,####
             #,!,,,,,,##
             #,,/,b,,,#                  r
             #,,,,@,,,,,,,,
             #?,,,r,,,#
       r  b ,#,,,,rb,,##
          r ,#,!,r,,,,#:
            , ###,####
                 + :#
           b    ,
                         b
                        r
    ║ [1]!)
      The bat hits you for 1.
      Picked up the potion of healing (12).
      The bat hits you for 1.
```

That is `golden/terminal-100x30-pickup.txt` — the real thing, out of a real pty.
`#` is a wall you can see, `:` one you only remember, `.` lit floor, `,` floor
you only remember, `+` a door, `>` the stair down, `@` you. The distinction
between *seen* and *visible* is the whole point of the two arrays, and it is
visible without colour at all.

---

## Build and run

The folder is self-contained. Everything it needs is in it.

```sh
YCC=/home/yun/Projects/compiler/refs/ycc.ref
# sha256 c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631

(ulimit -S -v 3670016; $YCC roguelike.y -o roguelike) </dev/null   # zero warnings

./roguelike                                        # interactive, until q or Escape
./roguelike --frames 5 --no-tty --seed 1          # the deterministic run (== EXPECTED)
./roguelike --size 128x64 --frames 0 --no-tty     # just the biggest dungeon
./roguelike --check 200                           # the generator + FOV validator
./roguelike --walk l,1lljjkk --frames 40 --depth 4 --no-tty --seed 7
./roguelike --frames 300 --no-tty --invuln --quiet --time   # heap and wall clock
python3 pty_check.py ./roguelike                  # drive the alt screen from Python
```

> **The compiler pin moves.** `examples/ORCHESTRATOR.md` §3 pins
> `refs/ycc.ref` by *path* and quotes a hash; while this example was being
> written the pin moved again, from `e27f83e4801f9436…` to
> `c53cc41524a7baa2…` at 18:17 on 2026-10-04. Everything here was built and
> every number below was measured against `c53cc41524a7baa2…`, and the whole
> thing was rebuilt from scratch against `e27f83e4…` with zero warnings and
> byte-identical `EXPECTED` — `EXPECTED` is a property of the LCG in `rnd.y` and
> of nothing in the compiler.

### Keys, interactive

| key | what |
|---|---|
| arrows, `h` `j` `k` `l` | move. **That plus `y` `u` `b` `n` is all eight directions** |
| `H` `J` `K` `L` `Y` `U` `B` `N` | the same, for the second hand on the keyboard |
| `.` | wait one turn — you can see it coming, which matters |
| `,` or `g` | pick up what you are standing on |
| `1` … `8` | use that pack slot: drink the potion, read the scroll, ready the dagger |
| `?` | help overlay |
| `q`, `Q`, Escape | quit — always through `term.restore_all_exit(0)` |

`w`, `a`, `s`, `d` and `e` are deliberately **not** bound: this is a vi-keyed
roguelike and `hjkl`/`yubn` is the convention. (An earlier default *walk* string
used them, which cost three silent no-op turns — see the note on `DEF_WALK`.)

### Options

```
  -n, --frames N    run exactly N turns, then exit 0 (default 0: play until q)
  -s, --seed N      random seed, 0..; the same seed gives the same dungeon and walk
  --size VALUE      dungeon size WxH, 21x15 .. 128x64 (default 40x24)
  -d, --depth N     how many levels to descend before you win (default 3)
  -w, --walk VALUE  the scripted walk for --no-tty: hjkl yubn move, , grab, 1-8 use
  --no-tty          print the dungeon as text instead of drawing a terminal
  -Q, --quiet       no per-turn digest lines; the map and the summary still print
  --invuln          monsters cannot hurt you — a measurement aid
      --check N     validate the generator and the field of view over N levels
      --time        report wall clock, turns per second and the heap delta
  -h, --help        print this message and exit
```

`--frames N` means the same thing on both paths: under `--no-tty` it prints the
digest table, the map and the summary, which is what `EXPECTED` holds; on a
terminal it plays N turns, prints a one-line summary on stderr and restores the
terminal. Note that a turn needs a *key* to happen on a terminal — and bumping a
wall costs no turn — so `--frames` there means "once N keys' worth of turns have
gone by", and a walk that cannot reach N simply keeps waiting.

---

## The algorithms

### 1. Rooms and corridors — `dungeon.y`, 451 lines

Four hundred placement attempts for a rectangle 3–8 by 3–6 at a random position,
each kept only if its rectangle *inflated by one cell* touches no room already
placed. Then room *i*'s centre is joined to room *i*+1*'s centre by an L whose
elbow goes horizontal-then-vertical or the other way on a coin flip.

Three properties, and all three are asserted rather than hoped for:

* **Rooms do not overlap.** `boxes_touch` compares inflated rectangles, so two
  rooms never share a wall either — which is what leaves somewhere for a
  corridor to run.
* **Corridors connect.** A corridor is carved *only over `T_WALL`*, so it cannot
  punch a hole through a door or the stairs, and both its ends are room **centres**
  which are already floor. A corridor cannot stop one tile short of its room.
* **Nobody is stranded.** `check_reachable()` floods from the player's start over
  every non-wall tile — breadth-first, a fixed `[long; 8192]` queue, four
  neighbours — and then requires every room centre and the stairs to be in the
  fill. A level with fewer than two rooms cannot be connected at all, so the
  generator retries up to eight times with a deterministically derived seed and
  *reports failure* rather than returning a broken dungeon.

The stairs go in the **last** room, so the walk to the exit crosses every corridor
the level has.

Doors are hung on the last tile the *final* segment of a corridor actually
changed — the one in the doorway — on a 45 % coin flip, so some rooms have one
and some do not. A closed door is opaque **and** blocks, which is what
`DOOROPEN` exists for: one extra array rather than a wider tile, because a wider
tile would double the cost of the field-of-view loop for every tile on the map.

Measured over 200 levels (`golden/check-200.txt`):

| | |
|---|---|
| rooms per level | 10 – 24, mean 19 |
| floor coverage | 40 – 57 % of the map, mean 48 % |
| tiles lit at radius 8 | mean 98 |
| reach failures | **0** |
| generator retries needed | 0 |

### 2. Field of view — `fov.y`, 285 lines

**Symmetric-permissive, and deliberately not recursive shadowcasting.** The brief
offered either; this is the second, and the whole algorithm is one sentence:

> a tile is visible when the straight segment from the eye to that tile's centre
> crosses no opaque tile — with the corner exception that a segment grazing a
> corner between two tiles is blocked only when **both** of them are opaque.

`compute(cx, cy, r)` scans the square of the radius (289 candidates at r = 8,
minus the corners outside the circle) and asks `los` about each. No octant
multiplier table, no half-cell slope window, no fixed point — and therefore no
`fx`, and nothing to get subtly wrong.

**Symmetry is by construction, not by luck.** `los` is a monotone supercover DDA
walking cell centres, and a DDA is *not* symmetric: Bresenham's error term breaks
ties in the direction of travel, so walking A→B and B→A can visit different
cells. So the walk is first **canonicalised** — the endpoints are swapped until
`bx >= ax`, which is always possible — and after that the walk for (A, B) *is*
the walk for (B, A). That one `if (x1 < x0)` is the entire symmetry argument.

The permissive corner rule is one comparison instead of two: when a step advances
both x and y the segment passes exactly through a corner shared by two tiles, so
it is blocked only if both are opaque. That is the difference between a doorway
you can see edge-on and one you cannot.

Off the map is opaque, so light cannot leak round the border. `VIS` is one fixed
`[long; 8192]` cleared by a flat 8192-iteration loop — O(cells) rather than O(map)
on purpose, because it is one tight loop with no index arithmetic, and it beats a
per-row loop with a multiply in it.

### 3. The turn loop — `game.y`, 815 lines

No `break`, no `continue` — both are undefined names today
(`ORCHESTRATOR.md` §2.9; `TODO.md` §5 has them on the roadmap). Everything is
written with two idioms:

* **Early exit is an `else if` chain.** `turn(dx, dy)` needs four outcomes —
  off the map, a shut door, a wall, a monster — and needs them to stop. That is
  the chain, with no flag anywhere in it:

  ```y
  def turn(dx: long, dy: long) -> long {
      if (STATUS != S_ALIVE) { return 0; };
      let nx = PX + dx;
      let ny = PY + dy;
      let spent = 0;
      if (!dungeon.in_map(nx, ny)) {
          say(MSG_WALL, 0);
      } else if (dungeon.tile_at(nx, ny) == rules.T_DOOR
                 && !dungeon.is_open_door(nx, ny)) {
          dungeon.open_door(nx, ny);
          say(MSG_DOOR, 0);
          spent = 1;
      } else if (dungeon.blocks(nx, ny)) {
          say(MSG_WALL, 0);
      } else {
          let mi = monster_at(nx, ny);
          if (mi >= 0) { player_hits(mi); spent = 1; }
          else { spent = walk_to(nx, ny); };
      };
      spent
  };
  ```

  That third arm is not decoration. An earlier version had only the off-map and
  the door arm, and **`w` walked the player straight into the masonry**; the
  position invariant inside `--check` caught it on turn 5 of a level. The chain is
  also the only thing keeping the player inside the walls at all.

* **A skip is a positive condition.** `monsters_act` wants to skip dead monsters
  and monsters out of sight, so it wraps the body instead of jumping over it:

  ```y
  if (MALIVE[i] == 1 && STATUS == S_ALIVE) {
      if (adjacent)      { attack_player(i); }
      else if (in_sight) { step_towards(i); };
  };
  ```

* **A bounded search runs its guard down.** `free_floor` finds a spare tile by
  rejection, and instead of `break` it counts down — `while (tries < 60)` — and
  answers `-1` when it gives up, which is a defined answer rather than a spin.

  The one thing that bit me here is worth repeating, because it is the shape of
  the bug, not of the fix: `spawn_monsters` and `spawn_items` first held a `live`
  flag *beside* the loop and only refreshed it in the collision branch. After the
  last wanted monster was placed, `live` was still true from the top of that
  iteration, and the loop quietly kept going until it happened to hit an occupied
  tile — 36 monsters on a level that asked for 28, reported as `mn = 28`. The fix
  is two conditions in the `while` and nothing to forget to update:

  ```y
  while (placed < want && guard < cap) { ... };
  ```

### 4. What the rules are

Hit points 20; bare hands do 2, a dagger 5. Five species (giant rat, bat, snake,
orc, troll) and one more point of damage each per level of depth, so a depth-5
rat is not a depth-1 rat with more hit points. Monsters move only when they are
**in your field of view**, one greedy step, and attack when adjacent — which is
what makes a corridor a safe place to rest and what makes the explored/visible
distinction a mechanic and not a decoration. Walking into a wall costs no turn.
Walking into a shut door opens it and costs one. Walking onto the stairs
descends. Reaching the bottom escapes with the amulet of Y.

---

## What to look at

| file | what |
|---|---|
| `fov.y` | `los` — 70 lines, the whole visibility relation, and the `if (x1 < x0)` that makes it symmetric |
| `dungeon.y` | `boxes_touch`, `connect`, `flood`, `check_reachable` — the generator and the assertion that it works |
| `game.y` | `turn` and `monsters_act` — the two idioms that replace `break` and `continue` |
| `rules.y` | the two record unions, and the three things about them the language makes you know |
| `view.y` | `tile_at` — one per-tile decision, drawn two ways from one place |
| `roguelike.y` | `check_run` — the validator, and the split between what it asserts and what it only reports |
| `textout.y` | the fixed byte sink: the only way to print Unicode without touching the heap |
| `golden/` | the deterministic run, the pty screens, `--check 200`, a descent, a 128×64 level, a wall bump, the 10 000-turn heap run |

### Record unions: three things the language makes you know

`type Terrain = Rock | Floor | Door | Stairs;` and
`type Loot = Gold | Potion | Scroll | Dagger;` are the natural shape here, and
`match` is the natural way to read one. Three things about Y shaped how they are
used, and each cost an afternoon:

1. **A `match` whose arms are records cannot be a block's value.** With the union
   as the declared return type this is a hard error:

   ```
   error: 'pick' body: expected { tag: long } | { tag: long, wear: long }, got void
   ```

   The same match with `str` arms, or with `long` arms, is fine; so is a match
   whose arms are values *already typed as the union*. So every `match` in
   `rules.y` returns a scalar — a name, a number, a glyph — and **no code in this
   folder builds a union except `make_*` and four module-level constants.** The
   union is read, never rebuilt.
2. **An arm binding copies; a destructuring pattern reads in place.**
   `Potion p => …` copies the member record out of the union before `p` is bound;
   `Potion { heal } => …` reads `heal` where it lies. Both are right for a read,
   so `rules.y` uses the destructuring form wherever one field is wanted (it also
   says which field) and a binding only where the whole record is.
3. **A module cannot have a `const T_WALL = 0` and a `let T_WALL: Terrain`.** The
   record wins, after which `rules.T_STAIRS` is a *union* and
   `tile_at(x, y) == rules.T_STAIRS` is `error: '==' compares long with {…} | {…}`.
   The four union values are `U_ROCK`…`U_STAIRS` for exactly that reason.

And a union value is a heap record — 40 bytes, built whenever the expression runs
— so every call into `rules.y` is on a cold path: a level built once, an item
named when it is picked up, a message rendered when it changes. The frame path
works on plain `long` codes.

### Memory: `heap_used()` is a number in the output, not a claim

The heap is an arena and nothing is ever freed (`ORCHESTRATOR.md` §2.7), so a
per-turn allocation is a leak with a fixed stride. Every buffer here is a
module-level fixed array, allocated once at module load:

| | bytes |
|---|---|
| `dungeon.TILE` + `DOOROPEN` + `REACH` + `QUEUE` | 4 × 8192 longs = 256 KiB |
| `game.SEEN` + `game.ITEM` + `game.ICNT` | 3 × 8192 longs = 192 KiB |
| `fov.VIS` | 8192 longs = 64 KiB |
| `tui`'s capture buffer (module level, allocated even headless) | 256 KiB |
| `textout.ob`, plus the game and view scratch | 64 KiB + 5 KiB |
| **the headless baseline, measured** | **`heap_used() = 876720` — 856 KiB** |
| `fb.new(rows, cols)` on the interactive path | 1.5 MiB more (the same 856 KiB → 2 336 KiB, and it stays there) |

There is not one array literal, record literal or string concatenation below a
module-level binding in this folder. The two places it nearly happened are
recorded in the code: `place_start_potion`'s two `[long; 8]` offsets (hoisted, so a
descent costs **0** bytes) and `view.sline`'s digit scratch (module-level, so the
status line costs 0 bytes a frame).

Two findings from measuring it, both of which are in the code:

* **The message log was a leak with a frame count in it.** `game.message_line(i)`
  builds a `str` — it has to, to splice the name of the monster you just hit into
  the sentence — and a Y string built at run time lives on a heap that is never
  freed. Drawing the log every frame measured **33 bytes a frame on a screen
  that had settled to nothing but one health bar**. Two fixes, both in: the log
  is drawn only when its contents change (`view.MSGID/MSGSUB/MSGFLAG`), and the
  text is composed into a fixed `[long; 160]` of byte values rather than a string
  at all (`game.message_line_bytes`). Zero now.
* **`use_slot` is the one allocation left.** It returns a `rules.Loot` **by
  value**, and returning a union copies its record: **40 bytes, once per keypress
  on a pack slot**. The obvious fix is not available — a module-level array of
  unions cannot be written at all (`let INV: [Loot; 8] = [0; 0; …]` is a parse
  error) — so the example measures it and says so rather than hiding it.

**Measured**, `golden/heap-10000-turns.txt`:

```
$ ./roguelike --walk . --frames 10000 --no-tty --seed 1 --invuln --quiet --time
roguelike: 10000 turns in 167592 us = 16 us/turn, heap_used 876720 -> 876720 delta 0
10000 turns in 10000 frames  depth  1/ 3  hp  20/ 20  …  heap    0 B over 10000 frames
```

10 000 real turns — each one a full field-of-view recompute over 289 candidate
tiles plus a monster pass — at **0 bytes** of heap and **16 µs** a turn. The
`heap 0 B` column is in every `--no-tty` summary line, so the golden run asserts
it too.

The interactive path is measured the same way, from a pty, and its one-line
summary reports the delta on every exit:

```
40 keys of "." then q      roguelike: 10343 bytes of ANSI, heap_used 2448000 -> 2448000, delta 0
40 keys of RIGHT then q   roguelike: 27252 bytes of ANSI, heap_used 2448000 -> 2448000, delta 0
60 mixed keys then q      roguelike: 17806 bytes of ANSI, heap_used 2448000 -> 2448168, delta 168
```

0 bytes over forty frames of a settled screen, and 0 bytes over forty frames of
walking into a wall — where every key is a *free* turn and the frame still gets
drawn, redrawn and diffed. The 168 is the sixty-key run, six of whose keys were
`1`: the `use_slot` union copy, six times over, as predicted.

### `str + byte` and the legend

`str + byte` dereferences the byte's numeric value as a pointer and dies with
**SIGSEGV**. It is filed as **`examples/BUGS.md` → "`str + byte` segfaults —
`print("x" + "abc"[0]);` crashes the program"**.

```
$ refs/ycc.ref min.y -o min && ./min      # print("x" + "abc"[0]);
Segmentation fault
```

Both workarounds were verified. **This example uses
`legend += chr(GLYPHS[i]);`** — `view.build_legend`, the only place a string is
built one character at a time, at start-up. `+=` is the form the filing documents;
`chr()` returns a real `str` and is what the code uses, for a measured reason:
`chr` builds its one-character string **on the heap, about 80 bytes a call**, so
it is right four times at start-up and wrong on any per-frame path. Everything on
the frame path writes codepoints into the framebuffer directly instead — `fb.put`,
which is why the status line costs nothing.

The counter-intuitive part is that `+=` and `+` *disagree*: `line = line + R[i]`
compiles and segfaults, while `line += R[i]` was the documented way round it —
and against the current pin `line += R[i]` is now a **compile error**
(`error: '+=` string: expected str, got byte`) on all four builds in the tree.
That is filed separately; see the filings section.

### No `float` anywhere, and no math functions

There is no `float` → `long` and no cast syntax (`ORCHESTRATOR.md` §2.4a), and
there is no `sin`/`cos`/`sqrt`/`PI` at all (§2.4b), so all the arithmetic is
integer. The generator needs none of it: rooms, corridors, a flood fill and a
pack of RNG calls. The field of view needs none of it either — which is half of
why the segment-predicate FOV was chosen over a slope-based shadowcaster, whose
slopes *would* have needed `fx`'s Q30 fixed point. The one place trigonometry
appears is `fov.ray`, the second implementation kept only for `--check` to compare
against, and it uses `fx.sin`/`fx.cos` in Q30.

### Determinism

There is no unseeded randomness on any path. `--seed` defaults to 1, the whole run
is a pure function of (seed, size, depth, walk), and nothing reads the clock, the
pid or `getrandom`. `clock_us` appears once — the `--time` report, on **stderr**,
which `EXPECTED` never contains. The headless path is a *scripted* walk, not a
random one: same seed and same flags, same bytes.

---

## The validator: `./roguelike --check 200`

`golden/check-200.txt`. Four checks are **asserted** (any non-zero exits 1) and
five are **reported**, and the split is deliberate:

**Asserted**

* `reach failures` — flood from the start, require every room centre and the
  stairs in the fill. The classic roguelike bug, caught here and not by a player.
* `symmetry breaks` — every tile the player can see can see the player back. This
  is the defining property of a symmetric field of view and the one that catches
  a leak *and* an over-shadow.
* `neighbour misses` — every walkable 8-neighbour of the eye is visible.
* `batch/los disagree` — `fov.compute` must mark exactly the tiles `fov.los`
  accepts, and nothing outside the radius. A sharp, cheap consistency check on the
  two entry points into one predicate, which is where a bounds bug would live.
* `walk failures` — 60 turns of the *same scripted walk the deterministic run
  uses*, per level: no trap, the player always on a walkable tile, hit points
  never out of range, the generator never reported failure. Over 200 levels that
  is 12 000 turns.

**Reported**

* rooms per level, floor coverage, tiles lit, kills, deepest level reached
* `ray misses of los` / `ray-only, corner` — `fov.ray` is a **second, independent
  implementation** of the same idea (no DDA, no error term, trigonometry instead
  of integer stepping), and it is in the tree to be read and compared. It is
  **not** an oracle, and pretending otherwise would be dishonest: a raymarch and a
  segment walk are two approximations of one curve and they disagree in *both*
  directions, on the tiles where a ray grazes a corner and the permissive rule
  decides. Over 200 levels: 1184 tiles `los` lights that a 2048-ray,
  4-samples-per-cell march misses, and 1481 the other way — about six each way per
  level, every one a corner case. So "the field of view respects walls" rests on
  the four assertions above plus `los` being short enough to read in full.

**Seeds run: 21 of them, 2 400 levels in total, zero assertion failures.**

| run | seeds | levels |
|---|---|---|
| the shipped `golden/check-200.txt` | 1 | 200 |
| a deeper soak | 1 | 500 |
| two sizes each | 1, 7, 12345, 999999, 424242 | 880 |
| a forty-level sweep | 2, 3, 4, 5, 6, 8, 11, 13, 16, 21, 23, 28, 30, 33, 34, 55, 89, 144, 233, 377 | 800 |

Map sizes 40×24 to 72×36, six distinct shapes, cycling with the level index.
Every run printed `check OK`; `reach failures`, `symmetry breaks`,
`neighbour misses`, `batch/los disagree` and `walk failures` were 0 in all of
them. Three 5 000-turn soaks on top of that, with three different walks: no trap,
`heap_used` delta 0, 16 µs a turn.

---

## The interactive path, under a pty

`tmux` is not installed on this machine, so `pty_check.py` allocates a pty from
Python, sets the window size **before** `execv` (`pty.fork()` gives 0×0, and
TIOCGWINSZ would then report nothing), feeds keys, and replays the byte stream
through a twenty-line terminal emulator — because `tui` writes each row with an
absolute CUP and no newline, so the frame is not readable out of the byte stream
without one.

```sh
(ulimit -S -v 3670016; timeout 60 python3 pty_check.py ./roguelike) </dev/null
```

```
bytes from the pty      : 10968
alt screen entered     : True
alt screen left        : True
cursor hidden / shown  : True / True
c_lflag before / after : 0x8a3b 0x8a3b
cooked mode restored   : True
lflag identical        : True
exit status            : 0
RESULT                 : PASS
```

The interactive loop is `tui`'s pattern verbatim — raw mode, alt screen,
watchdog, and **one** place that leaves:

```y
if (!term.raw_mode()) { eputs("roguelike: not a terminal; try --frames N --no-tty\n"); exit(1); };
term.enter_screen();
term.arm_watchdog();
...
term.restore_all_exit(0);
```

Y has no `atexit` and no signal handler, so there is no path out of that loop
that does not restore the terminal. The watchdog is armed, which is what covers
`kill -9` and a crash.

---

## The std units this uses

Copied in from `examples/_toolkit/` and **not edited** — this folder is
self-contained and does not import across folders (`ORCHESTRATOR.md` §4).

| file | sha256 (16) | lines | what |
|---|---|---|---|
| `fx.y` | `4b47a9bfef0c1e30` | 687 | integer Q30 fixed-point maths — used only by `fov.ray` |

`tui` comes from std and is imported, but only `--time` uses it — the game itself never
paces, because a turn-based roguelike waits for a key.

Two things worth knowing about `args`, both found by this example:

* **Do not declare a `--help` option.** `args` recognises `--help` only when the
  spec does *not* declare it; declaring a BOOL called `help` makes it an ordinary
  flag, so `--help` prints nothing and the program falls through to the
  interactive path and dies with `not a terminal`.
* `args.parse` returns `USAGE` (2) with the message already on stderr; this
  program exits **1** after printing `roguelike: try --help`, so every diagnostic
  in this folder is `exit 1` on stderr, as the brief asks.

---

## Filings

Appended to `examples/BUGS.md` (append-only, per `ORCHESTRATOR.md` §8):

* **`+=` on a string with a `byte` is now a compile error** — the documented
  workaround for the filed `str + byte` crash no longer compiles. `line = line +
  R[i]` still compiles and still SIGSEGVs, `line += R[i]` is now
  `error: '+=` string: expected str, got byte` on all four builds in the tree, and
  `chr()` is the only form left. Minimal reproduction is the filing's own snippet.

Everything else the example needed was already correct behaviour and was worked
around rather than filed: syscall argument order, the ioctl constants, VTIME/VMIN
at bytes 22/23, traps on stdout, no `break`/`continue`, no cast syntax, no maths
library, `split` dropping a trailing empty field, `join` putting the separator
first, and `print` being the reason a record's value costs nothing when it is
passed to a `def` but 40 bytes when the literal is evaluated.

Two of my own bugs are written up in the source, because they are the kind that a
golden file hides:

* `spawn_monsters`/`spawn_items` placed 36 of a wanted 28 through a `live` flag
  that was only refreshed in one branch (`game.y`).
* `view.ascii_at` drew the player as a remembered floor tile, because
  `cp = T_YOU` was a pre-assignment and the `seen` arm overwrote it (`view.y`).

And one that was a compiler trap rather than a bug of mine, found by hand-counting
a string literal: `while (i < 11) { s += chr(RAMP[i]) }` over a ten-character
ramp indexes out of bounds, and the bound is a **runtime trap on stdout**, so it
corrupted the output instead of failing to build. `build_legend` uses
`len(ASCII)` now, with the reason in a comment.

---

## The gate

```sh
$ ../../gate.py roguelike
=== gate: roguelike ===
=== roguelike: 8/8 passed ===
```

Verified here, each with the command and the result:

1. **Compiles with the pinned `$YCC`, zero warnings.** All eight of this folder's
   own `.y` files build clean individually as well as together.
   `-W 1` is also clean for this folder's own code; the only `-W 1` output left is
   dropped `fb.put`/`fb.text`/`fb.hline` return values in `view.y`, which are the
   frozen toolkit's `-> long` signature and cannot be changed.
2. **`./gate.py roguelike` reports 8/8.**
3. **The `run=` line, twice, byte-identical and matching `EXPECTED`** — 2293 bytes.
4. **No trap on any path.** Every one of `--size 0x0`, `1x1`, `0x24`, `40x0`,
   `40`, `abc`, `999x999`, `--depth 0`, `--depth -1`, `--depth 41`,
   `--seed -1`, `--seed abc`, `--frames -3`, `--check -5`, `--walk l,l,z`,
   `--walk ""`, `--bogus`, a missing value for `--frames`/`--seed`/`--size`/
   `--walk`, a stray operand, and `--walk hhhhhhhhhhhhhh` (fourteen turns walking
   straight into a wall) is a clean diagnostic on stderr with **exit 1** and an
   empty stdout. The walk-into-a-wall run costs 0 bytes of heap and ends
   `3 turns in 14 frames … heap 0 B` (`golden/wall-bump.txt`).
5. **Generation validity.** 200 levels at seed 1, 500 more, and 120 each at seeds
   7, 12345 and 999999, over six map sizes: **0 reach failures**, and the stairs
   were reachable in every one.
6. **No per-turn allocation.** `heap_used()` delta **0** over 10 000 real turns
   (`--walk .` so every frame spends one), at 15 µs a turn.
7. **Interactive path under a Python pty:** alt screen in and out, cursor hidden
   and shown, `c_lflag` identical before and after, exit 0 on `q`.
8. **Standalone.** Copied alone to a fresh directory, built and produces the same
   2293 bytes.

### The gate line

```
build=../../refs/ycc.ref roguelike.y -o roguelike
run=./roguelike --frames 5 --no-tty --seed 1
```

### Pin re-verification

The compiler was reblessed mid-campaign to
`refs/ycc.ref` sha256
`6dcd7071f2fe387585a4fa7a05c92bf7821b68a70449ed5ada732724bfb8898e`.
Rebuilt against it: **zero warnings**, the deterministic run still
reproduces `EXPECTED` byte for byte, no trap on any path, and this
folder's own property check still passes. No source change was needed.
Earlier pins stay listed above as history.

## Pin re-verification: `4a58dd5d` (orchestrator, 2026-10-04)

`refs/ycc.ref` moved again, `6dcd7071` -> **`4a58dd5d3dc88425354854cdb6b153c4b6ec8e54e6c0e65be65a7d0a25483ab8`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8
all pass and `EXPECTED` is reproduced **byte for byte** over two runs, so
the golden, the answers and the property-check result in this README are
unchanged. The only thing that had fallen out of date was this sha
record, which is what gate item 0 caught.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should
be able to see the history rather than infer it from a single number.

## Pin re-verification: `e55fa8d0` (orchestrator, 2026-10-04)

`refs/ycc.ref` moved again, `4a58dd5d` -> **`e55fa8d08a151d2aa8482370b3b79dd2f6a7b99760eecb876b094c90814a76ab`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8
all pass and `EXPECTED` is reproduced **byte for byte** over two runs, so
the golden, the answers and the property-check result in this README are
unchanged. Gate item 0 caught the stale record and nothing else did.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should
be able to see the history rather than infer it from a single number.

## Pin re-verification: `9ce37629` (orchestrator, 2026-10-04)

`refs/ycc.ref` moved again, `e55fa8d0` -> **`9ce376290e6fbe71629f51c871ff3cae8f498543a8ac3e0d7a0d8049e35946e7`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8
all pass and `EXPECTED` is reproduced **byte for byte** over two runs.
Gate item 0 caught the stale record and nothing else did.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should
be able to see the history rather than infer it from one number.

## Pin re-verification: `5eba0d66` (orchestrator, 2026-10-04)

`refs/ycc.ref` moved again, `e55fa8d0` -> **`5eba0d66059520a9d28f5cdae57fd99835bb6ae62110bf4d2a794ae5fced484b`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8
all pass and `EXPECTED` is reproduced **byte for byte** over two runs.
Gate item 0 caught the stale record and nothing else did.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should
be able to see the history rather than infer it from one number.

## Pin re-verification: `625efd81` (orchestrator, 2026-10-05)

`refs/ycc.ref` moved again, `5eba0d66` -> **`625efd81934531f6afee595bb47f5dbb680a6cb3f485b4856b9a9259ceea824b`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8 all
pass and `EXPECTED` is reproduced **byte for byte** over two runs. Gate item
0 caught the stale record and nothing else did -- across all 36 folders at
once, which is the signature of a pin move rather than of a regression.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should be
able to see the history rather than infer it from one number.

## Pin re-verification: `1d28b3db` (orchestrator, 2026-10-05)

`refs/ycc.ref` moved again, `625efd81` -> **`1d28b3dbcc546b5fc0e3f9d541b56777f746cd3e10122b45ba42f4904fd191d3`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8 all
pass and `EXPECTED` is reproduced **byte for byte** over two runs. Gate item
0 caught the stale record and nothing else did -- across all 36 folders at
once, which is the signature of a pin move rather than of a regression.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should be
able to see the history rather than infer it from one number.

## Pin re-verification: `31808ddc21adfa31` (orchestrator, 2026-10-05)

`refs/ycc.ref` moved again, `1d28b3dbcc546b5fc0e3f9d541b56777f746cd3e10122b45ba42f4904fd191d3` -> **`31808ddc21adfa31398f6337fa6dd6bfe585d25beceab20498b6914b89485755`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8 all
pass and `EXPECTED` is reproduced **byte for byte** over two runs. Gate item
0 caught the stale record and nothing else did -- across all 39 folders at
once, which is the signature of a pin move rather than of a regression.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should be
able to see the history rather than infer it from one number.

## Pin re-verification: `289cf022002903a6` (orchestrator, 2026-10-05)

`refs/ycc.ref` moved again, `e39a5e21785f599184f55deafad3ff17b4d05edb01cebc0a513e0cb7907f517d` -> **`289cf022002903a695c1ca339816b0f8f478aa3ef9f00643a93c3a95947f979c`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8 all
pass and `EXPECTED` is reproduced **byte for byte** over two runs. Gate item
0 caught the stale record and nothing else did -- across all 39 folders at
once, which is the signature of a pin move rather than of a regression.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should be
able to see the history rather than infer it from one number.
