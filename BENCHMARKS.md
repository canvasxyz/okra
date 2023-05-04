# Benchmarks

Since Okra is built on top of LMDB and exposes the same external key/value store interface, we can compare Okra's performance to using LMDB directly. The numbers here were produced on a 2021 M1 MacBook Pro with 32GB RAM running macos 13.1 with a 1TB SSD.

The entries are small, with 4-byte keys (monotonically increasing u32s) and 8-byte values (the Blake3 hash of a random seed).

> ℹ️ The very rough takeaway here is that, when compared to baseline LMDB performance, Okra can do about 1/2 the ops/s for reads, and between 2/3 to 1/10 the ops/s for writes, depending mostly on the size of the database and the way that transactions are batched.

## LMDB benchmarks

Run the LMDB benchmarks:

```sh
$ zig build bench-lmdb
```

### DB size: 1,000 entries

|                                | iterations |   min (ms) |   max (ms) |   avg (ms) |      std |    ops / s |
| :----------------------------- | ---------: | ---------: | ---------: | ---------: | -------: | ---------: |
| read 1 random entry            |        100 |     0.0022 |     0.0246 |     0.0026 |   0.0022 |     377423 |
| read 100 random entries        |        100 |     0.0658 |     0.0740 |     0.0678 |   0.0014 |    1474408 |
| iterate over all entries       |        100 |     0.1211 |     0.1804 |     0.1268 |   0.0064 |    7888842 |
| set 1 random entry             |        100 |     0.0631 |     0.2526 |     0.0842 |   0.0264 |      11875 |
| set 1,000 random entries       |         10 |     3.9490 |     4.0699 |     3.9827 |   0.0425 |     251087 |
| set 50,000 random entries      |         10 |   191.9905 |   194.4517 |   192.7986 |   0.7813 |     259338 |

### DB size: 50,000 entries

|                                | iterations |   min (ms) |   max (ms) |   avg (ms) |      std |    ops / s |
| :----------------------------- | ---------: | ---------: | ---------: | ---------: | -------: | ---------: |
| read 1 random entry            |        100 |     0.0024 |     0.0319 |     0.0040 |   0.0032 |     251274 |
| read 100 random entries        |        100 |     0.0796 |     0.1179 |     0.0838 |   0.0058 |    1192688 |
| iterate over all entries       |        100 |     5.9836 |     6.1446 |     6.0093 |   0.0335 |    8320390 |
| set 1 random entry             |        100 |     0.0621 |     0.9963 |     0.1111 |   0.1043 |       9004 |
| set 1,000 random entries       |         10 |     4.6655 |     4.8867 |     4.7414 |   0.0654 |     210907 |
| set 50,000 random entries      |         10 |   210.9363 |   215.7202 |   212.1709 |   1.4640 |     235659 |

### DB size: 1,000,000 entries

|                                | iterations |   min (ms) |   max (ms) |   avg (ms) |      std |    ops / s |
| :----------------------------- | ---------: | ---------: | ---------: | ---------: | -------: | ---------: |
| read 1 random entry            |        100 |     0.0029 |     0.0288 |     0.0043 |   0.0025 |     233757 |
| read 100 random entries        |        100 |     0.1306 |     0.3272 |     0.1623 |   0.0269 |     616222 |
| iterate over all entries       |        100 |   120.0190 |   122.8945 |   120.6397 |   0.4316 |    8289144 |
| set 1 random entry             |        100 |     0.0743 |     1.0675 |     0.1109 |   0.1080 |       9017 |
| set 1,000 random entries       |         10 |    14.9315 |    19.5559 |    18.0191 |   1.4681 |      55497 |
| set 50,000 random entries      |         10 |   264.3104 |   279.4472 |   268.9975 |   3.9378 |     185875 |

## Okra benchmarks

Run the Okra benchmarks:

```sh
$ zig build bench-okra
```

### DB size: 1,000 entries

|                                | iterations |   min (ms) |   max (ms) |   avg (ms) |      std |    ops / s |
| :----------------------------- | ---------: | ---------: | ---------: | ---------: | -------: | ---------: |
| read 1 random entry            |        100 |     0.0037 |     0.0315 |     0.0043 |   0.0028 |     234697 |
| read 100 random entries        |        100 |     0.0751 |     0.0899 |     0.0785 |   0.0025 |    1274615 |
| iterate over all entries       |        100 |     0.1876 |     0.2220 |     0.1960 |   0.0068 |    5101186 |
| set 1 random entry             |        100 |     0.1390 |     0.5133 |     0.2129 |   0.0595 |       4696 |
| set 1,000 random entries       |         10 |    99.9940 |   130.6624 |   114.1629 |   8.9427 |       8759 |
| set 50,000 random entries      |         10 |  5404.6063 |  5716.8699 |  5576.6957 | 119.2690 |       8966 |

### DB size: 50,000 entries

|                                | iterations |   min (ms) |   max (ms) |   avg (ms) |      std |    ops / s |
| :----------------------------- | ---------: | ---------: | ---------: | ---------: | -------: | ---------: |
| read 1 random entry            |        100 |     0.0037 |     0.0375 |     0.0059 |   0.0035 |     170117 |
| read 100 random entries        |        100 |     0.0886 |     0.1592 |     0.0945 |   0.0104 |    1058182 |
| iterate over all entries       |        100 |     9.2539 |     9.8010 |     9.3332 |   0.0965 |    5357195 |
| set 1 random entry             |        100 |     0.1998 |     1.1763 |     0.3324 |   0.1150 |       3008 |
| set 1,000 random entries       |         10 |   185.1957 |   226.0065 |   200.2623 |  10.3417 |       4993 |
| set 50,000 random entries      |         10 |  9777.7026 | 10435.8003 | 10090.3509 | 207.7945 |       4955 |

### DB size: 1,000,000 entries

|                                | iterations |   min (ms) |   max (ms) |   avg (ms) |      std |    ops / s |
| :----------------------------- | ---------: | ---------: | ---------: | ---------: | -------: | ---------: |
| read 1 random entry            |        100 |     0.0052 |     0.0428 |     0.0072 |   0.0047 |     139057 |
| read 100 random entries        |        100 |     0.1461 |     0.2502 |     0.1798 |   0.0252 |     556217 |
| iterate over all entries       |        100 |   188.7296 |   193.8046 |   189.5443 |   0.8198 |    5275811 |
| set 1 random entry             |        100 |     0.2498 |     1.1822 |     0.3867 |   0.1168 |       2586 |
| set 1,000 random entries       |         10 |   274.5737 |   295.4067 |   286.4128 |   5.6272 |       3491 |
| set 50,000 random entries      |         10 | 15009.5366 | 16055.5033 | 15533.0363 | 315.5509 |       3219 |
