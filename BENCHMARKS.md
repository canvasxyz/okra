# Benchmarks

Run on a 2021 M1 MacBook Pro with 32GB RAM running macos 13.1.

## LMDB benchmarks

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