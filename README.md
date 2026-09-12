# Pure Elixir Roaring bitmap PoC

No packages, NIFs, Rust, C, or Mix project needed. Run with Elixir 1.20+:

```sh
elixir test.exs
elixir bench.exs
# Optional shorter run:
ROUNDS=20 CORPUS=10 REPEATS=3 elixir bench.exs
```

`bench.exs` writes `results.csv`. The included `results.txt` captures the default run.

## Workload

Both `100.64.0.0/11` and `fd00:2021:1111::/107` contain 2^21 = 2,097,152
addresses. Store `integer_ip - integer_network_base`, giving offsets
0 through 2,097,151 inclusive. Keep a separate bitmap for each network:
the same offset in the two networks denotes different addresses.

The script generates 20 independent samples of exactly 10,000 distinct offsets
for each range, using a fixed random seed. Sorted and unsorted comparisons use
the same membership. IP conversion, sampling, preparation of sorted inputs, and
preparation of existing bitmaps are outside timing. Each replacement removes
one present offset and inserts one absent offset, preserving cardinality.

## Implementation

`roaring.exs` implements immutable Roaring-style two-level containers:

- The high 16 bits select a container in an Elixir map.
- Up to 4,096 low-16-bit values are stored in a sorted, packed binary (2 bytes/value).
- Denser containers store bits in a BEAM arbitrary-precision integer, with a count.
- Insert/remove binary-search sparse containers and copy only the affected
  container plus the outer map. No-op updates preserve membership.
- Differences compare containers, skip equal contents, and merge sparse arrays.

This follows the array/bitset split and cardinality threshold in the
[Roaring format specification](https://github.com/RoaringBitmap/RoaringFormatSpec).
It is a PoC, not a complete interoperable Roaring library: no run containers,
portable serialization, or other set operations. Dense operations are implemented
and tested, but their enumeration/conversion paths prioritize simplicity. The
10k uniformly distributed workload uses sparse containers (~312 values/container,
32 containers), so these results do not characterize dense performance.

The array payload is 20,000 bytes per 10k-member bitmap, excluding BEAM binary,
map, and tuple overhead. This is not a measurement of total process memory.

```elixir
Code.require_file("roaring.exs", __DIR__)
old = PureRoaring.from_list([123, 5, 100_000])
new = old |> PureRoaring.remove(5) |> PureRoaring.insert(42)
added = PureRoaring.difference(new, old) |> PureRoaring.to_list() # [42]
removed = PureRoaring.difference(old, new) |> PureRoaring.to_list() # [5]
```

## Measurements

- **Build / random:** general constructor, including its internal sort.
- **Build / sorted (general API):** same constructor given already-sorted input.
- **Build / sorted (sorted API):** checked linear constructor; skips sorting.
- **Sort only:** isolates Elixir sorting cost.
- **Sort + sorted build:** explicit end-to-end equivalent of the random constructor;
  included as a consistency check, not a separate algorithm.
- **Insert / remove:** one successful immutable edit to a prebuilt bitmap.
- **Apply known remove + add:** two edits, with both offsets already known.
- **Diff existing old/new:** computes both `new - old` and `old - new`. Both
  snapshots already exist; the new one was independently built, not derived
  with shared update containers.
- **Rebuild random new + diff:** constructs the new snapshot from 10k unsorted
  offsets and then discovers additions/removals. Existing old bitmap is prebuilt.

The final section measures both ranges sequentially in one operation: 20k total
offsets for builds, or two removals plus two insertions for known updates.

Default run: 60 rounds, each averaging 100 operations per scenario per range
(20 samples repeated 5 times). Scenario order is shuffled each round after
warmup. Each measured batch runs in a fresh process with the same input corpus;
startup, input copying, and initial GC are excluded. Allocations and any GC
inside the measured batch are included. Outputs are computed and discarded;
this models transient construction/update cost, not retaining snapshot history.
Immutable inputs ensure every update starts from the same valid baseline.

Reported median/p95/min are statistics of **batch mean time per operation**.
The p95 is not individual-request tail latency. These are single-process local
microbenchmarks, not throughput under concurrency. Microsecond edits include
loop/function dispatch overhead. No IP parsing, serialization, I/O, or network
latency is timed. Seeds and corpus sizes make inputs reproducible; timings still
vary with system load and BEAM/CPU versions.

`test.exs` checks boundaries, duplicate handling, invalid input, array/bitset
promotion and demotion, all container difference combinations, and randomized
operations against `MapSet`. The benchmark also checks each sample and delta
before timing.

## Local result

Apple M2 Pro, aarch64 macOS, Elixir 1.20.0 / OTP 29. Four ExUnit tests passed.
For a single 10k-offset bitmap, the observed median batch averages were:

| Operation | IPv4 | IPv6 |
|---|---:|---:|
| Build from random offsets | 1,314 µs | 1,348 µs |
| Build from sorted offsets (sorted API) | 822 µs | 838 µs |
| Insert one absent offset | 0.831 µs | 0.835 µs |
| Remove one present offset | 0.797 µs | 0.793 µs |
| Apply known remove + add | 1.219 µs | 1.227 µs |
| Discover both differences, snapshots prebuilt | 124 µs | 125 µs |
| Rebuild random new snapshot + discover differences | 1,342 µs | 1,389 µs |

Already-sorted input was about 1.6x faster to build. Known edits were about
1,100x faster than rebuilding. Receiving a full list and discovering its changes
still pays the rebuild cost. The two IP families perform similarly because the
stored offset domain and occupancy are identical. These conclusions apply to
this implementation and sparse workload; see raw CSV for all scenarios and the
combined-range measurements. Separately measured sort and build times need not
add exactly: allocation and garbage-collection behavior differs when combined.

## One-element diff follow-up

Run `elixir diff_bench.exs`; captured output is in `diff_results.txt`.
This focused benchmark checks add-only and remove-only changes. It computes
`{new - old, old - new}` after an immutable update to a 10k-member bitmap.
The snapshots share unchanged containers; the earlier benchmark independently
rebuilt its replacement snapshot and changed two members. This harness also
carries a smaller input corpus per worker, so its GC conditions differ and
these timings are not a controlled speedup comparison with the earlier run.

Median batch-average diff-only time was 17.4–17.6 microseconds for either change
and either IP family. Update-plus-diff measured 15.4–16.3 microseconds; separate
microbenchmarks can run faster due to sharing, heap/GC behavior, and noise,
so do not interpret subtraction of these measurements as update cost.

Each result contains exactly one changed offset: a singleton bitmap on one side
and an empty bitmap on the other. The singleton low-16 array payload is 2 bytes,
but that excludes its high-16 container key and all structural overhead. The
full `{added_bitmap, removed_bitmap}` tuple measures 129 bytes with uncompressed
`term_to_binary/1` (ETF), or 272 bytes via `:erts_debug.flat_size/1 * wordsize`
(a flat heap diagnostic, not total process memory or allocator usage).
ETF is not the portable Roaring serialization format. A custom delta message
could instead use one uint32 offset (4 bytes) plus a one-byte add/remove tag,
excluding framing and network identification; no such wire codec is implemented.

## Full 20k-set memory

`elixir memory.exs` measures two separate 10k-member bitmaps (one per IP family).
See `memory_results.txt`. On this 64-bit OTP 29 runtime, the pair occupies
40,000 bytes of packed array payload plus 6,848 bytes of reachable BEAM heap
structures, totaling **46,848 bytes (45.75 KiB)**. This includes the tuple holding
the two bitmaps and accounts for shared heap terms. Each bitmap separately is
23,424 bytes. All 64 container binaries are off-heap, with no excess referenced
backing-buffer capacity in this sample; their payload must be added to
`:erts_debug.size/1 * wordsize`.

An isolated process retaining only the pair after GC reports 13,816 bytes of
process memory, plus 40,000 bytes of off-heap binary payload: 53,816 bytes
(52.55 KiB). This includes process/heap capacity overhead and varies with GC.
Neither estimate includes off-heap binary allocation headers, allocator rounding,
or shared VM/code overhead, so these are not exact RSS figures. Input lists,
old snapshots, and temporary construction allocations are excluded. The
uncompressed ETF serialization of the pair is 41,135 bytes, a different metric.

## 100k and 1m per-stack runs

Run `elixir scale_bench.exs`, or select a workload with
`SIZES=1000000 ROUNDS=5 CORPUS=2 elixir scale_bench.exs`.
The Roaring implementation is unchanged from the 10k measurements. This harness
runs every earlier operation at each density, including both stacks together,
and saves CSV timings plus full-set/diff sizes. Sampling and full membership/delta
correctness checks happen before timing. Five shuffled measurement rounds use
two independent random samples per stack. Each round repeats build/sort work once
per sample, diffs twice, and individual updates 500 times. Reported min/median/max
are batch means; this smaller run does not estimate request-level tail latency.

Workers receive only the inputs their operation needs. This limits memory when
handling million-element lists and prevents list copying/retention from distorting
single-offset benchmarks. Worker startup, input copying, and initial GC are outside
timing. This changes heap/GC conditions relative to the original 10k harness;
absolute cross-run ratios are indicative rather than a controlled scaling study.
Already-sorted timings exclude the initial sort. Both-way diffs produce added and
removed bitmaps. Known edits return new immutable bitmaps. The old/new two-edit
diff uses independently built snapshots; single-edit diffs use updated snapshots.

Memory is reachable BEAM heap (`:erts_debug.size * wordsize`) plus backing bytes
of off-heap array binaries. Dense bitsets are BEAM big integers already counted
in heap size and are not added twice. This includes live bitmap structures but
excludes owner-process spare heap, allocator overhead, build temporaries, original
lists, and retained snapshots. ETF is uncompressed `term_to_binary`, not portable
Roaring serialization. Tiny diff binaries live on the heap. The sharing-aware
single-diff footprint is 248 bytes; the earlier 272-byte figure used `flat_size`
which counts shared structures repeatedly.

At 100k/stack, all 64 containers across the two stacks are sparse arrays and
total live memory is 406,848 bytes (397.31 KiB). At 1m/stack, all 64 are bitsets
and total live memory is 528,064 bytes (515.69 KiB). The serialized full pair is
401,135 and 525,870 bytes respectively. Each one-element diff is still 248 bytes
of sharing-aware live heap / 129 bytes ETF; a one-add-plus-one-remove diff is
320 bytes of live heap / 147 bytes ETF.

The high-density results expose a deliberate simplicity in the original PoC:
`subtract/2` on two dense containers computes the bitwise difference, then
`lows/1` enumerates all 65,536 positions, even for an empty or singleton result.
Both-way single-element diffs enumerate the changed container twice. This makes
diff discovery much slower at 1m/stack despite the tiny result. Dense bulk builds
also repeatedly allocate growing BEAM integers. These are implementation costs,
not a fundamental bound on Roaring algorithms; this rerun leaves them unchanged.
