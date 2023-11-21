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
| get random 1 entry       |        100 |   0.0012 |   0.0155 |   0.0015 | 0.0014 |   665952 |
| get random 100 entries   |        100 |   0.0180 |   0.0208 |   0.0186 | 0.0003 |  5369586 |
| iterate over all entries |        100 |   0.0193 |   0.0203 |   0.0195 | 0.0001 | 51381996 |
| set random 1 entry       |        100 |   0.0764 |   0.2021 |   0.1058 | 0.0235 |     9449 |
| set random 100 entries   |        100 |   0.6907 |   1.3886 |   0.8780 | 0.1055 |   113893 |
| set random 1k entries    |         10 |   7.3615 |   8.9078 |   8.0422 | 0.4619 |   124343 |
| set random 50k entries   |         10 | 374.3335 | 399.1279 | 385.2390 | 7.5832 |   129790 |

### 50k entries

|                          | iterations | min (ms) | max (ms) | avg (ms) |     std |  ops / s |
| :----------------------- | ---------: | -------: | -------: | -------: | ------: | -------: |
| get random 1 entry       |        100 |   0.0011 |   0.0146 |   0.0020 |  0.0013 |   490901 |
| get random 100 entries   |        100 |   0.0247 |   0.0687 |   0.0287 |  0.0067 |  3487459 |
| iterate over all entries |        100 |   0.6859 |   0.8188 |   0.6988 |  0.0222 | 71549195 |
| set random 1 entry       |        100 |   0.0819 |   0.6926 |   0.1155 |  0.0677 |     8658 |
| set random 100 entries   |        100 |   1.9632 |   2.5755 |   2.2194 |  0.1270 |    45056 |
| set random 1k entries    |         10 |  16.4453 |  20.7063 |  19.1991 |  1.4259 |    52086 |
| set random 50k entries   |         10 | 727.0792 | 761.0945 | 739.6718 | 12.0248 |    67598 |

### 1m entries

|                          | iterations |  min (ms) |  max (ms) |  avg (ms) |     std |  ops / s |
| :----------------------- | ---------: | --------: | --------: | --------: | ------: | -------: |
| get random 1 entry       |        100 |    0.0015 |    0.0309 |    0.0031 |  0.0029 |   325822 |
| get random 100 entries   |        100 |    0.0723 |    0.1632 |    0.1039 |  0.0204 |   962796 |
| iterate over all entries |        100 |   14.4925 |   16.2743 |   14.8588 |  0.3732 | 67300077 |
| set random 1 entry       |        100 |    0.1061 |    0.8227 |    0.1579 |  0.0797 |     6333 |
| set random 100 entries   |        100 |    3.1606 |    7.3933 |    6.0721 |  0.5558 |    16469 |
| set random 1k entries    |         10 |   32.3621 |   44.5188 |   41.3779 |  4.4194 |    24167 |
| set random 50k entries   |         10 | 1079.2927 | 1122.4023 | 1099.2155 | 14.0221 |    45487 |

## LMDB benchmarks

Copied from https://github.com/canvasxyz/zig-lmdb for reference.

### 1k entries

|                          | iterations | min (ms) | max (ms) | avg (ms) |    std |  ops / s |
| :----------------------- | ---------: | -------: | -------: | -------: | -----: | -------: |
| get random 1 entry       |        100 |   0.0009 |   0.0142 |   0.0012 | 0.0013 |   859298 |
| get random 100 entries   |        100 |   0.0164 |   0.0178 |   0.0170 | 0.0002 |  5865959 |
| iterate over all entries |        100 |   0.0173 |   0.0181 |   0.0173 | 0.0001 | 57723023 |
| set random 1 entry       |        100 |   0.0613 |   0.1613 |   0.0826 | 0.0181 |    12109 |
| set random 100 entries   |        100 |   0.0930 |   0.4078 |   0.1249 | 0.0327 |   800633 |
| set random 1k entries    |         10 |   0.4011 |   0.4233 |   0.4124 | 0.0077 |  2424709 |
| set random 50k entries   |         10 |  15.8565 |  16.9226 |  16.1385 | 0.3964 |  3098176 |

### 50k entries

|                          | iterations | min (ms) | max (ms) | avg (ms) |    std |  ops / s |
| :----------------------- | ---------: | -------: | -------: | -------: | -----: | -------: |
| get random 1 entry       |        100 |   0.0008 |   0.0135 |   0.0017 | 0.0013 |   582686 |
| get random 100 entries   |        100 |   0.0236 |   0.0561 |   0.0282 | 0.0058 |  3546626 |
| iterate over all entries |        100 |   0.6060 |   0.6867 |   0.6203 | 0.0175 | 80607307 |
| set random 1 entry       |        100 |   0.0553 |   0.6738 |   0.0759 | 0.0661 |    13170 |
| set random 100 entries   |        100 |   0.3644 |   0.5885 |   0.4624 | 0.0404 |   216278 |
| set random 1k entries    |         10 |   0.9273 |   1.3168 |   1.0381 | 0.1162 |   963267 |
| set random 50k entries   |         10 |  23.0990 |  25.0138 |  23.5197 | 0.6563 |  2125879 |

### 1m entries

|                          | iterations | min (ms) | max (ms) | avg (ms) |    std |  ops / s |
| :----------------------- | ---------: | -------: | -------: | -------: | -----: | -------: |
| get random 1 entry       |        100 |   0.0010 |   0.0288 |   0.0028 | 0.0028 |   360359 |
| get random 100 entries   |        100 |   0.0498 |   0.1970 |   0.0746 | 0.0314 |  1339794 |
| iterate over all entries |        100 |  12.2684 |  13.0028 |  12.3550 | 0.1304 | 80939213 |
| set random 1 entry       |        100 |   0.0630 |   0.7330 |   0.0827 | 0.0683 |    12098 |
| set random 100 entries   |        100 |   0.6055 |   3.5569 |   2.2590 | 0.3394 |    44267 |
| set random 1k entries    |         10 |   7.2128 |  17.8363 |  13.0217 | 3.1923 |    76795 |
| set random 50k entries   |         10 |  53.1443 |  62.6031 |  56.2486 | 2.6658 |   888911 |
