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
| ---------------------------------------- | ---------- | -------- | -------- | -------- | -------- | ---------- |
| - read 1 random entry                    |        100 |      583 |    15541 |     1242 |     1584 |     805152 |
| - iterate over all entries               |        100 |    12708 |    41666 |    13075 |     2874 |   76481835 |

| **INITIAL DB SIZE: 100,000 ENTRIES**     | iterations | min (ns) | max (ns) | avg (ns) |      std |    ops / s |
| ---------------------------------------- | ---------- | -------- | -------- | -------- | -------- | ---------- |
| - read 1 random entry                    |        100 |      334 |     7166 |     1167 |      668 |     856898 |
| - iterate over all entries               |        100 |   502084 |   877000 |   515284 |    39882 |  194067737 |

### Writes

| **INITIAL DB SIZE: 0 ENTRIES**           | iterations | min (ns) | max (ns) | avg (ns) |      std |    ops / s |
| ---------------------------------------- | ---------- | -------- | -------- | -------- | -------- | ---------- |
| - set 1 random entry                     |        100 |    58708 |   188750 |    82509 |    17894 |      12119 |
| - set 1,000 random entries               |        100 |   384375 |   511167 |   424155 |    22397 |    2357628 |
| - set 100,000 random entries             |         10 | 45679667 | 48239083 | 46377829 |   916548 |    2156202 |

| **INITIAL DB SIZE: 1,000 ENTRIES**       | iterations | min (ns) | max (ns) | avg (ns) |      std |    ops / s |
| ---------------------------------------- | ---------- | -------- | -------- | -------- | -------- | ---------- |
| - set 1 random entry                     |        100 |    62250 |   118541 |    77384 |     9575 |      12922 |
| - set 1,000 random entries               |        100 |   463000 |   581750 |   504900 |    23000 |    1980590 |
| - set 100,000 random entries             |         10 | 46344292 | 52600708 | 47491712 |  1766516 |    2105630 |

| **INITIAL DB SIZE: 100,000 ENTRIES**     | iterations | min (ns) | max (ns) | avg (ns) |      std |    ops / s |
| ---------------------------------------- | ---------- | -------- | -------- | -------- | -------- | ---------- |
| - set 1 random entry                     |        100 |    80875 |  2384458 |   140605 |   226528 |       7112 |
| - set 1,000 random entries               |        100 |  2860458 |  8235708 |  3469212 |   937571 |     288249 |
| - set 100,000 random entries             |         10 | 59472041 | 73811083 | 63169941 |  4393324 |    1583031 |

## okra benchmarks

Run the okra benchmarks:

```sh
$ zig build bench
```

### Reads

| **INITIAL DB SIZE: 1,000 ENTRIES**       | iterations |   min (ns) |   max (ns) |   avg (ns) |        std |    ops / s |
| ---------------------------------------- | ---------- | ---------- | ---------- | ---------- | ---------- | ---------- |
| - read 1 random entry                    |        100 |        500 |       4667 |        734 |        470 |    1362397 |
| - iterate over all entries               |        100 |      15000 |      31000 |      15480 |       1824 |   64599483 |

| **INITIAL DB SIZE: 100,000 ENTRIES**     | iterations |   min (ns) |   max (ns) |   avg (ns) |        std |    ops / s |
| ---------------------------------------- | ---------- | ---------- | ---------- | ---------- | ---------- | ---------- |
| - read 1 random entry                    |        100 |        750 |      21417 |       1872 |       2013 |     534188 |
| - iterate over all entries               |        100 |    1483458 |    2233208 |    1500571 |      74555 |   66641298 |

### Writes

| **INITIAL DB SIZE: 0 ENTRIES**           | iterations |   min (ns) |   max (ns) |   avg (ns) |        std |    ops / s |
| ---------------------------------------- | ---------- | ---------- | ---------- | ---------- | ---------- | ---------- |
| - set 1 random entry                     |        100 |      56167 |     132250 |      73931 |      13202 |      13526 |
| - set 1,000 random entries               |        100 |    3525875 |    3850750 |    3588204 |      59171 |     278690 |
| - set 100,000 random entries             |         10 |  817558334 |  822123708 |  819215591 |    1391187 |     122067 |

| **INITIAL DB SIZE: 1,000 ENTRIES**       | iterations |   min (ns) |   max (ns) |   avg (ns) |        std |    ops / s |
| ---------------------------------------- | ---------- | ---------- | ---------- | ---------- | ---------- | ---------- |
| - set 1 random entry                     |        100 |      76667 |     192833 |      92241 |      15082 |      10841 |
| - set 1,000 random entries               |        100 |    5438291 |    5715042 |    5503969 |      65907 |     181687 |
| - set 100,000 random entries             |         10 |  822453667 |  825450958 |  823494608 |     902777 |     121433 |

| **INITIAL DB SIZE: 100,000 ENTRIES**     | iterations |   min (ns) |   max (ns) |   avg (ns) |        std |    ops / s |
| ---------------------------------------- | ---------- | ---------- | ---------- | ---------- | ---------- | ---------- |
| - set 1 random entry                     |        100 |     115083 |     218416 |     163241 |      21886 |       6125 |
| - set 1,000 random entries               |        100 |   12606833 |   28564041 |   13196749 |    1587755 |      75776 |
| - set 100,000 random entries             |         10 |  965650833 |  977246500 |  969638508 |    3794264 |     103131 |

One observation here is that batching many writes in one transaction is not as relatively efficient with okra as it is in LMDB itself: setting 100k entries in one transaction is 200x faster than setting one entry in 100k transactions when using LMDB directly, but only 16x faster when using okra. In other words, batching writes still is still effective, but its effectiveness diminishes.