# Benchmarks

Since okra is built on top of LMDB and exposes the same external key/value store interface, we can compare okra's performance to using LMDB directly.

Run on a 2021 M1 MacBook Pro with 32GB RAM running macos 13.1.

## LMDB benchmarks

Run the LMDB benchmarks:

```sh
$ zig build bench-lmdb
```

### Reads

| **INITIAL DB SIZE: 1,000 ENTRIES**       | iterations | min (ns) | max (ns) | avg (ns) |      std |    ops / s |
| :--------------------------------------- | ---------: | -------: | -------: | -------: | -------: | ---------: |
| - read 1 random entry                    |        100 |      584 |    12583 |     1255 |     1340 |     796812 |
| - iterate over all entries               |        100 |    12708 |    46584 |    13115 |     3364 |   76248570 |

| **INITIAL DB SIZE: 100,000 ENTRIES**     | iterations | min (ns) | max (ns) | avg (ns) |      std |    ops / s |
| :--------------------------------------- | ---------: | -------: | -------: | -------: | -------: | ---------: |
| - read 1 random entry                    |        100 |      334 |     3875 |     1355 |      519 |     738007 |
| - iterate over all entries               |        100 |   502000 |   963292 |   518669 |    53865 |  192801189 |

### Writes

| **INITIAL DB SIZE: 0 ENTRIES**           | iterations | min (ns) | max (ns) | avg (ns) |      std |    ops / s |
| :--------------------------------------- | ---------: | -------: | -------: | -------: | -------: | ---------: |
| - set 1 random entry                     |        100 |    65250 |   161792 |    81069 |    13513 |      12335 |
| - set 1,000 random entries               |        100 |   392500 |   807333 |   436663 |    50716 |    2290095 |
| - set 100,000 random entries             |         10 | 45627959 | 51163708 | 46470983 |  1607157 |    2151880 |

| **INITIAL DB SIZE: 1,000 ENTRIES**       | iterations | min (ns) | max (ns) | avg (ns) |      std |    ops / s |
| :--------------------------------------- | ---------: | -------: | -------: | -------: | -------: | ---------: |
| - set 1 random entry                     |        100 |    71416 |  2085750 |   121170 |   248372 |       8252 |
| - set 1,000 random entries               |        100 |   488125 |  2166792 |   562974 |   190445 |    1776280 |
| - set 100,000 random entries             |         10 | 45844667 | 48664084 | 46436383 |   898384 |    2153483 |

| **INITIAL DB SIZE: 100,000 ENTRIES**     | iterations | min (ns) | max (ns) | avg (ns) |      std |    ops / s |
| :--------------------------------------- | ---------: | -------: | -------: | -------: | -------: | ---------: |
| - set 1 random entry                     |        100 |    85042 |   161333 |   116155 |    18836 |       8609 |
| - set 1,000 random entries               |        100 |  2760166 |  4085667 |  2928474 |   143763 |     341474 |
| - set 100,000 random entries             |         10 | 53271292 | 54007667 | 53664796 |   247949 |    1863418 |

## okra benchmarks

Run the okra benchmarks:

```sh
$ zig build bench
```

### Reads

| **INITIAL DB SIZE: 1,000 ENTRIES**       | iterations |   min (ns) |   max (ns) |   avg (ns) |        std |    ops / s |
| :--------------------------------------- | ---------: | ---------: | ---------: | ---------: | ---------: | ---------: |
| - read 1 random entry                    |        100 |       1459 |      38208 |       2532 |       3709 |     394944 |
| - iterate over all entries               |        100 |      31834 |      68375 |      36797 |       4078 |   27176128 |

| **INITIAL DB SIZE: 100,000 ENTRIES**     | iterations |   min (ns) |   max (ns) |   avg (ns) |        std |    ops / s |
| :--------------------------------------- | ---------: | ---------: | ---------: | ---------: | ---------: | ---------: |
| - read 1 random entry                    |        100 |        792 |       8000 |       1566 |        833 |     638569 |
| - iterate over all entries               |        100 |    1474209 |    2119083 |    1488058 |      63815 |   67201681 |

### Writes

| **INITIAL DB SIZE: 0 ENTRIES**           | iterations |   min (ns) |   max (ns) |   avg (ns) |        std |    ops / s |
| :--------------------------------------- | ---------: | ---------: | ---------: | ---------: | ---------: | ---------: |
| - set 1 random entry                     |        100 |      53583 |     175583 |      73927 |      21532 |      13526 |
| - set 1,000 random entries               |        100 |    3524291 |    3804459 |    3571479 |      50857 |     279996 |
| - set 100,000 random entries             |         10 |  816701459 |  825490125 |  818853604 |    2752241 |     122121 |

| **INITIAL DB SIZE: 1,000 ENTRIES**       | iterations |   min (ns) |   max (ns) |   avg (ns) |        std |    ops / s |
| :--------------------------------------- | ---------: | ---------: | ---------: | ---------: | ---------: | ---------: |
| - set 1 random entry                     |        100 |      78416 |     406375 |     101929 |      38154 |       9810 |
| - set 1,000 random entries               |        100 |    5441000 |    5734875 |    5480564 |      41995 |     182462 |
| - set 100,000 random entries             |         10 |  821669250 |  825782583 |  823093595 |    1135792 |     121492 |

| **INITIAL DB SIZE: 100,000 ENTRIES**     | iterations |   min (ns) |   max (ns) |   avg (ns) |        std |    ops / s |
| :--------------------------------------- | ---------: | ---------: | ---------: | ---------: | ---------: | ---------: |
| - set 1 random entry                     |        100 |     116333 |     233583 |     161107 |      25084 |       6207 |
| - set 1,000 random entries               |        100 |   12621666 |   16425708 |   13300831 |     925134 |      75183 |
| - set 100,000 random entries             |         10 |  970185375 |  982211875 |  973464266 |    3468337 |     102725 |

One observation here is that batching many writes in one transaction is not as relatively efficient with okra as it is in LMDB itself: setting 100k entries in one transaction is 200x faster than setting one entry in 100k transactions when using LMDB directly, but only 16x faster when using okra. In other words, batching writes still is still effective, but its effectiveness diminishes.