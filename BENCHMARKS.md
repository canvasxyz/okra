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
| get random 1 entry       |        100 |   0.0003 |   0.0188 |   0.0007 | 0.0018 |  1526881 |
| get random 100 entries   |        100 |   0.0136 |   0.0465 |   0.0146 | 0.0037 |  6831754 |
| iterate over all entries |        100 |   0.0156 |   0.0301 |   0.0161 | 0.0014 | 62114811 |
| set random 1 entry       |        100 |   0.0598 |   0.2311 |   0.0861 | 0.0214 |    11619 |
| set random 100 entries   |        100 |   0.6146 |   1.0475 |   0.7438 | 0.0753 |   134450 |
| set random 1k entries    |         10 |   6.0506 |   7.0473 |   6.4926 | 0.3083 |   154021 |
| set random 50k entries   |         10 | 293.4078 | 314.6179 | 303.9731 | 7.0198 |   164488 |

### 50k entries

|                          | iterations | min (ms) | max (ms) | avg (ms) |     std |  ops / s |
| :----------------------- | ---------: | -------: | -------: | -------: | ------: | -------: |
| get random 1 entry       |        100 |   0.0005 |   0.0184 |   0.0015 |  0.0017 |   671348 |
| get random 100 entries   |        100 |   0.0280 |   0.0882 |   0.0366 |  0.0102 |  2731337 |
| iterate over all entries |        100 |   0.7472 |   0.9332 |   0.8014 |  0.0414 | 62387702 |
| set random 1 entry       |        100 |   0.0777 |   0.6280 |   0.1233 |  0.0627 |     8112 |
| set random 100 entries   |        100 |   1.7313 |   2.6152 |   2.0117 |  0.2036 |    49709 |
| set random 1k entries    |         10 |  13.7858 |  18.0866 |  15.9815 |  1.3964 |    62572 |
| set random 50k entries   |         10 | 556.5583 | 604.0808 | 582.9106 | 12.3448 |    85776 |

### 1m entries

|                          | iterations | min (ms) | max (ms) | avg (ms) |     std |  ops / s |
| :----------------------- | ---------: | -------: | -------: | -------: | ------: | -------: |
| get random 1 entry       |        100 |   0.0010 |   0.0303 |   0.0025 |  0.0028 |   396109 |
| get random 100 entries   |        100 |   0.0805 |   0.1795 |   0.1161 |  0.0268 |   861299 |
| iterate over all entries |        100 |  16.6275 |  22.9953 |  17.3585 |  0.7477 | 57608659 |
| set random 1 entry       |        100 |   0.0975 |   0.3161 |   0.1409 |  0.0312 |     7095 |
| set random 100 entries   |        100 |   2.7560 |   7.7726 |   6.1888 |  0.6810 |    16158 |
| set random 1k entries    |         10 |  27.5993 |  40.6202 |  37.0383 |  4.7168 |    26999 |
| set random 50k entries   |         10 | 873.1435 | 926.1513 | 900.9426 | 16.2646 |    55497 |

## LMDB benchmarks

Copied from https://github.com/canvasxyz/zig-lmdb for reference.

### 1k entries

|                          | iterations | min (ms) | max (ms) | avg (ms) |    std |  ops / s |
| :----------------------- | ---------: | -------: | -------: | -------: | -----: | -------: |
| get random 1 entry       |        100 |   0.0003 |   0.0146 |   0.0006 | 0.0014 |  1623746 |
| get random 100 entries   |        100 |   0.0305 |   0.0364 |   0.0314 | 0.0007 |  3181302 |
| iterate over all entries |        100 |   0.0311 |   0.0340 |   0.0312 | 0.0003 | 32000020 |
| set random 1 entry       |        100 |   0.0931 |   0.3103 |   0.1256 | 0.0332 |     7959 |
| set random 100 entries   |        100 |   0.1151 |   0.2963 |   0.1441 | 0.0279 |   694063 |
| set random 1k entries    |         10 |   0.3931 |   0.4568 |   0.4322 | 0.0196 |  2313543 |
| set random 50k entries   |         10 |  12.2390 |  15.7186 |  12.8449 | 1.0957 |  3892584 |

### 50k entries

|                          | iterations | min (ms) | max (ms) | avg (ms) |    std |  ops / s |
| :----------------------- | ---------: | -------: | -------: | -------: | -----: | -------: |
| get random 1 entry       |        100 |   0.0002 |   0.0129 |   0.0011 | 0.0013 |   934868 |
| get random 100 entries   |        100 |   0.0250 |   0.0531 |   0.0280 | 0.0044 |  3566696 |
| iterate over all entries |        100 |   0.6055 |   0.6735 |   0.6173 | 0.0145 | 81001777 |
| set random 1 entry       |        100 |   0.0551 |   0.6420 |   0.0742 | 0.0610 |    13476 |
| set random 100 entries   |        100 |   0.3705 |   3.3370 |   0.4798 | 0.2896 |   208400 |
| set random 1k entries    |         10 |   0.8556 |   1.0658 |   0.9524 | 0.0709 |  1050002 |
| set random 50k entries   |         10 |  19.3440 |  21.0593 |  19.7118 | 0.5614 |  2536546 |

### 1m entries

|                          | iterations | min (ms) | max (ms) | avg (ms) |    std |  ops / s |
| :----------------------- | ---------: | -------: | -------: | -------: | -----: | -------: |
| get random 1 entry       |        100 |   0.0004 |   0.0211 |   0.0022 | 0.0022 |   462423 |
| get random 100 entries   |        100 |   0.0517 |   0.1809 |   0.0715 | 0.0251 |  1398510 |
| iterate over all entries |        100 |  12.2841 |  14.0215 |  12.4831 | 0.2681 | 80108379 |
| set random 1 entry       |        100 |   0.0645 |   1.4024 |   0.1043 | 0.1328 |     9587 |
| set random 100 entries   |        100 |   0.6773 |   7.3026 |   2.3796 | 0.6177 |    42025 |
| set random 1k entries    |         10 |   7.3463 |  15.9778 |  13.2091 | 2.9459 |    75705 |
| set random 50k entries   |         10 |  47.9222 |  60.7651 |  52.2927 | 3.4127 |   956156 |
