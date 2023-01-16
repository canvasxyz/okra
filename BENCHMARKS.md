# Benchmarks

Since okra is built on top of LMDB and exposes the same external key/value store interface, we can compare okra's performance to using LMDB directly.

Run on a 2021 M1 MacBook Pro with 32GB RAM running macos 13.1.

## LMDB benchmarks

Run the LMDB benchmarks:

```sh
$ zig build bench-lmdb
```

### Initial DB size: 0 entries

|                                | iterations | min (ns) | max (ns) | avg (ns) |      std |    ops / s |
| :----------------------------- | ---------: | -------: | -------: | -------: | -------: | ---------: |
| set 1 random entry             |        100 |    66750 |   362542 |   113852 |    45853 |       8783 |
| set 1,000 random entries       |        100 |   386833 |   525750 |   431689 |    28748 |    2316482 |
| set 100,000 random entries     |         10 | 45681125 | 49446625 | 46765441 |  1416505 |    2138331 |

### Initial DB size: 1,000 entries

|                                | iterations | min (ns) | max (ns) | avg (ns) |      std |    ops / s |
| :----------------------------- | ---------: | -------: | -------: | -------: | -------: | ---------: |
| set 1 random entry             |        100 |    62334 |   117750 |    78684 |    11293 |      12709 |
| set 1,000 random entries       |        100 |   466250 |  2333000 |   515969 |   183793 |    1938100 |
| set 100,000 random entries     |         10 | 45727500 | 49008333 | 46625970 |  1013617 |    2144727 |
| read 1 random entry            |        100 |      250 |     6125 |      435 |      598 |    2298850 |
| iterate over all entries       |        100 |     5125 |     9667 |     5450 |      448 |  183486238 |

### Initial DB size: 100,000 entries

|                                | iterations | min (ns) | max (ns) | avg (ns) |      std |    ops / s |
| :----------------------------- | ---------: | -------: | -------: | -------: | -------: | ---------: |
| set 1 random entry             |        100 |    79667 |  3027750 |   143362 |   290827 |       6975 |
| set 1,000 random entries       |        100 |  2792458 |  5252917 |  3142698 |   549748 |     318197 |
| set 100,000 random entries     |         10 | 53560208 | 56503875 | 54589008 |  1003741 |    1831870 |
| read 1 random entry            |        100 |      375 |     4833 |     1240 |      484 |     806451 |
| iterate over all entries       |        100 |   502166 |   975500 |   515189 |    49086 |  194103523 |

## okra benchmarks

Run the okra benchmarks:

```sh
$ zig build bench
```

### Initial DB size: 0 entries

|                                | iterations |   min (ns) |   max (ns) |   avg (ns) |        std |    ops / s |
| :----------------------------- | ---------: | ---------: | ---------: | ---------: | ---------: | ---------: |
| set 1 random entry             |        100 |      54750 |     152500 |      83623 |      18200 |      11958 |
| set 1,000 random entries       |        100 |    3524875 |    3775959 |    3569761 |      41319 |     280130 |
| set 100,000 random entries     |         10 |  817938000 |  823338292 |  820657520 |    1780655 |     121853 |

### Initial DB size: 1,000 entries

|                                | iterations |   min (ns) |   max (ns) |   avg (ns) |        std |    ops / s |
| :----------------------------- | ---------: | ---------: | ---------: | ---------: | ---------: | ---------: |
| set 1 random entry             |        100 |      76708 |     175875 |      92192 |      13124 |      10846 |
| set 1,000 random entries       |        100 |    5440250 |   16455459 |    5672313 |    1244540 |     176294 |
| set 100,000 random entries     |         10 |  823786625 |  827241208 |  825023404 |     968515 |     121208 |
| read 1 random entry            |        100 |        500 |       6292 |        800 |        648 |    1250000 |
| iterate over all entries       |        100 |      15458 |      24833 |      16051 |       1029 |   62301414 |

### Initial DB size: 100,000 entries

|                                | iterations |   min (ns) |   max (ns) |   avg (ns) |        std |    ops / s |
| :----------------------------- | ---------: | ---------: | ---------: | ---------: | ---------: | ---------: |
| set 1 random entry             |        100 |     110541 |     201792 |     157142 |      19421 |       6363 |
| set 1,000 random entries       |        100 |   12712917 |   16117041 |   13032209 |     568023 |      76732 |
| set 100,000 random entries     |         10 |  968104083 |  978815083 |  972955112 |    3946253 |     102779 |
| read 1 random entry            |        100 |        791 |       9334 |       1778 |        975 |     562429 |
| iterate over all entries       |        100 |    1472875 |    2207417 |    1487700 |      72757 |   67217853 |

One observation here is that batching many writes in one transaction is not as relatively efficient with okra as it is in LMDB itself: setting 100k entries in one transaction is 250x faster than setting one entry in 100k transactions when using LMDB directly, but only 16x faster when using okra. In other words, batching writes still is still effective, but its effectiveness diminishes.