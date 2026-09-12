# Pure Elixir Roaring: 100k and 1m per IP stack

Apple M2 Pro, Elixir 1.20.0, OTP 29. Unchanged PoC implementation; no NIFs or dependencies. Two independent seeded samples per stack, five shuffled rounds. Values are medians of batch means. Already-sorted builds exclude sorting. Raw CSVs include min/max and repetition counts.

## All timing results

### IPv4

| Operation | 100k per stack | 1m per stack |
|---|---:|---:|
| build random | 13.798 ms | 1.121 s |
| build sorted general API | 4.321 ms | 1.019 s |
| build sorted sorted API | 2.821 ms | 641.213 ms |
| sort only | 8.912 ms | 182.084 ms |
| sort plus sorted build | 13.702 ms | 1.247 s |
| insert one | 0.595 µs | 1.108 µs |
| remove one | 0.582 µs | 2.054 µs |
| apply remove plus add | 1.182 µs | 3.082 µs |
| diff existing old/new both ways | 254.792 µs | 103.300 ms |
| rebuild random new plus diff | 14.428 ms | 1.516 s |
| diff after one add | 135.917 µs | 47.337 ms |
| diff after one remove | 135.021 µs | 50.573 ms |
| one add plus compute diff | 133.760 µs | 65.049 ms |
| one remove plus compute diff | 140.614 µs | 78.998 ms |

### IPv6

| Operation | 100k per stack | 1m per stack |
|---|---:|---:|
| build random | 13.342 ms | 1.122 s |
| build sorted general API | 4.097 ms | 829.634 ms |
| build sorted sorted API | 2.790 ms | 711.516 ms |
| sort only | 8.480 ms | 178.462 ms |
| sort plus sorted build | 13.336 ms | 1.155 s |
| insert one | 0.601 µs | 0.892 µs |
| remove one | 0.579 µs | 2.175 µs |
| apply remove plus add | 1.233 µs | 2.885 µs |
| diff existing old/new both ways | 256.365 µs | 74.014 ms |
| rebuild random new plus diff | 15.233 ms | 1.009 s |
| diff after one add | 149.052 µs | 41.507 ms |
| diff after one remove | 140.958 µs | 51.494 ms |
| one add plus compute diff | 138.375 µs | 40.935 ms |
| one remove plus compute diff | 136.344 µs | 50.555 ms |

### both

| Operation | 100k per stack | 1m per stack |
|---|---:|---:|
| build random | 30.041 ms | 2.220 s |
| build sorted general API | 10.972 ms | 2.016 s |
| build sorted sorted API | 6.879 ms | 1.573 s |
| sort only | 22.574 ms | 285.543 ms |
| sort plus sorted build | 29.288 ms | 2.284 s |
| insert one | 1.180 µs | 1.988 µs |
| remove one | 1.181 µs | 3.951 µs |
| apply remove plus add | 2.502 µs | 5.924 µs |
| diff existing old/new both ways | 496.229 µs | 172.906 ms |
| rebuild random new plus diff | 40.665 ms | 2.377 s |
| diff after one add | 278.146 µs | 82.398 ms |
| diff after one remove | 284.969 µs | 101.839 ms |
| one add plus compute diff | 269.791 µs | 83.676 ms |
| one remove plus compute diff | 269.552 µs | 102.767 ms |

The `both` group processes both stacks sequentially: an insert/remove scenario edits once in each stack. A both-way diff returns additions and removals; it is separate from applying an already-known change.

## Sizes

| Measurement | 100k per stack | 1m per stack |
|---|---:|---:|
| Total entries | 200,000 | 2,000,000 |
| Containers across both stacks | 64 arrays | 64 bitsets |
| Live memory per stack | 203,424 B | 264,032 B |
| Live memory, both stacks | 406,848 B (397.31 KiB) | 528,064 B (515.69 KiB) |
| Uncompressed ETF, both stacks | 401,135 B | 525,870 B |
| One-element diff: live memory / ETF | 248 B / 129 B | 248 B / 129 B |
| One add + one remove diff: live memory / ETF | 320 B / 147 B | 320 B / 147 B |

Live memory includes reachable bitmap heap structures and off-heap binary payload. It excludes owner-process capacity, allocator overhead, temporary lists/build allocations, and retained snapshots. Diff sizes are for one stack’s `{added, removed}` result; the unchanged side is empty for a one-element change. ETF is Elixir external term format, not portable Roaring serialization.

## Interpretation

At 100k/stack the sample remains sparse (~3,125 members per container); at 1m/stack every container uses a fixed-size dense bitset. This keeps memory growth to about 30% despite 10x more entries.

The existing dense difference path enumerates all 65,536 bit positions per changed container to construct the output, even when the result is empty or a singleton. It is the principal cause of the slow 1m single-element diffs. Bulk dense construction also repeatedly allocates growing big integers. These are limitations of this PoC, not fundamental Roaring performance limits.

The scale harness copies only each job’s required inputs into fresh workers. Its heap/GC conditions and sampling budget differ from the original 10k harness, so comparisons against that run are approximate. Dense builds show substantial batch variability; inspect raw min/max values before treating small timing differences as significant.

All four ExUnit tests passed. Each generated sample also passed full membership, cardinality, sorted-constructor, immutable-update, and one-/two-element diff checks before timing.

Run: `elixir scale_bench.exs`. Details: [README](README.md).
