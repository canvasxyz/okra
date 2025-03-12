# Benchmarks

Since Okra is built on top of LMDB and exposes the same external key/value store interface, we can compare Okra's performance to using LMDB directly. The numbers here were produced on a 2021 M1 MacBook Pro with 32GB RAM running macos 13.1 with a 1TB SSD.

The entries are small, with 4-byte keys (monotonically increasing u32s) and 8-byte values (the Blake3 hash of a random seed).

> ℹ️ The rough takeaway here is that, compared to native LMDB, Okra has similar performance for reads, similar performance for small batches of writes, and degrades quickly for large batches of writes.

Another way of looking at this is that the overhead of opening and commiting a transaction dominates the cost of actually doing any work inside the transaction, even for LMDB.

## Okra benchmarks

```
zig build bench
```

### 1k entries

|                          | iterations | min (ms) | max (ms) | avg (ms) |    std |  ops / s |
| :----------------------- | ---------: | -------: | -------: | -------: | -----: | -------: |
| get random 1 entry       |        100 |   0.0003 |   0.0129 |   0.0006 | 0.0013 |  1560525 |
| get random 100 entries   |        100 |   0.0105 |   0.0235 |   0.0159 | 0.0057 |  6274825 |
| iterate over all entries |        100 |   0.0357 |   0.0493 |   0.0438 | 0.0028 | 22819724 |
| set random 1 entry       |        100 |   0.0603 |   0.2589 |   0.0803 | 0.0215 |    12460 |
| set random 100 entries   |        100 |   0.5327 |   1.0730 |   0.6498 | 0.0972 |   153896 |
| set random 1k entries    |         10 |   4.4319 |   5.1383 |   4.7913 | 0.2259 |   208713 |
| set random 50k entries   |         10 | 232.6683 | 250.3424 | 240.2418 | 5.5001 |   208124 |

### 50k entries

|                          | iterations | min (ms) | max (ms) | avg (ms) |    std |  ops / s |
| :----------------------- | ---------: | -------: | -------: | -------: | -----: | -------: |
| get random 1 entry       |        100 |   0.0003 |   0.0127 |   0.0013 | 0.0012 |   782001 |
| get random 100 entries   |        100 |   0.0168 |   0.0653 |   0.0225 | 0.0084 |  4452612 |
| iterate over all entries |        100 |   0.8860 |   1.1172 |   1.0134 | 0.0436 | 49341029 |
| set random 1 entry       |        100 |   0.0659 |   0.4763 |   0.0918 | 0.0480 |    10897 |
| set random 100 entries   |        100 |   1.3959 |   1.7380 |   1.5352 | 0.0705 |    65138 |
| set random 1k entries    |         10 |  10.6251 |  12.9539 |  11.8472 | 0.7474 |    84408 |
| set random 50k entries   |         10 | 442.1694 | 463.2281 | 449.4776 | 7.6731 |   111240 |

### 1m entries

|                          | iterations | min (ms) | max (ms) | avg (ms) |    std |  ops / s |
| :----------------------- | ---------: | -------: | -------: | -------: | -----: | -------: |
| get random 1 entry       |        100 |   0.0008 |   0.0215 |   0.0020 | 0.0020 |   489388 |
| get random 100 entries   |        100 |   0.0568 |   0.1383 |   0.0833 | 0.0200 |  1201195 |
| iterate over all entries |        100 |  17.7988 |  23.1545 |  19.8717 | 1.1129 | 50322714 |
| set random 1 entry       |        100 |   0.0780 |   0.4264 |   0.1009 | 0.0339 |     9911 |
| set random 100 entries   |        100 |   2.2006 |   4.8062 |   4.3359 | 0.3231 |    23063 |
| set random 1k entries    |         10 |  23.0527 |  31.5380 |  29.1960 | 3.0276 |    34251 |
| set random 50k entries   |         10 | 692.9426 | 713.3481 | 701.4627 | 6.7222 |    71280 |

## LMDB benchmarks

Copied from https://github.com/canvasxyz/zig-lmdb for reference.

### 1k entries

|                          | iterations | min (ms) | max (ms) | avg (ms) |    std |  ops / s |
| :----------------------- | ---------: | -------: | -------: | -------: | -----: | -------: |
| get random 1 entry       |        100 |   0.0001 |   0.0069 |   0.0002 | 0.0007 |  4082799 |
| get random 100 entries   |        100 |   0.0089 |   0.0204 |   0.0118 | 0.0045 |  8473664 |
| iterate over all entries |        100 |   0.0175 |   0.0290 |   0.0221 | 0.0023 | 45156084 |
| set random 1 entry       |        100 |   0.0498 |   0.1814 |   0.0582 | 0.0159 |    17169 |
| set random 100 entries   |        100 |   0.0750 |   0.1275 |   0.0841 | 0.0068 |  1189692 |
| set random 1k entries    |         10 |   0.2495 |   0.2606 |   0.2557 | 0.0035 |  3911596 |
| set random 50k entries   |         10 |   8.8281 |  12.4414 |   9.8183 | 1.1449 |  5092551 |

### 50k entries

|                          | iterations | min (ms) | max (ms) | avg (ms) |    std |  ops / s |
| :----------------------- | ---------: | -------: | -------: | -------: | -----: | -------: |
| get random 1 entry       |        100 |   0.0002 |   0.0072 |   0.0011 | 0.0008 |   914620 |
| get random 100 entries   |        100 |   0.0194 |   0.0562 |   0.0232 | 0.0058 |  4312356 |
| iterate over all entries |        100 |   0.4243 |   0.7743 |   0.5451 | 0.0315 | 91727484 |
| set random 1 entry       |        100 |   0.0446 |   0.3028 |   0.0577 | 0.0263 |    17342 |
| set random 100 entries   |        100 |   0.3673 |   0.6541 |   0.4756 | 0.0776 |   210273 |
| set random 1k entries    |         10 |   0.7499 |   0.9015 |   0.8379 | 0.0474 |  1193519 |
| set random 50k entries   |         10 |  14.2130 |  14.7817 |  14.4931 | 0.1797 |  3449915 |

### 1m entries

|                          | iterations | min (ms) | max (ms) | avg (ms) |    std |  ops / s |
| :----------------------- | ---------: | -------: | -------: | -------: | -----: | -------: |
| get random 1 entry       |        100 |   0.0004 |   0.0270 |   0.0025 | 0.0029 |   397152 |
| get random 100 entries   |        100 |   0.0440 |   0.1758 |   0.0668 | 0.0198 |  1496224 |
| iterate over all entries |        100 |   9.9925 |  13.8858 |  10.6677 | 0.5131 | 93741223 |
| set random 1 entry       |        100 |   0.0538 |   0.3763 |   0.0721 | 0.0374 |    13874 |
| set random 100 entries   |        100 |   0.6510 |   2.2153 |   1.7443 | 0.1971 |    57330 |
| set random 1k entries    |         10 |   6.9965 |  11.5011 |  10.2719 | 1.6529 |    97353 |
| set random 50k entries   |         10 |  39.9164 |  42.6653 |  41.1931 | 1.0043 |  1213796 |
