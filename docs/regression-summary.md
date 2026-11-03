# Regression summary

A **design** build must pass every run. A **fault** build has a bug injected and must fail at least one run, which shows the checkers catch that kind of bug.

| build | expected | runs passed | result | first error seen |
|---|---|---|---|---|
| clean | pass | 9/9 | all runs pass |  |
| buggy | fail | 1/9 | fault caught by 8/9 runs | [model] ERROR: tRFC violation during Activate |
| fi_tras | fail | 0/9 | fault caught by 9/9 runs | [model] ERROR: tRAS minimum violation during Precharge to bank # |
| fi_trcd | fail | 0/9 | fault caught by 9/9 runs | [model] ERROR: tRCD violation during Write |
| fi_trp | fail | 0/9 | fault caught by 9/9 runs | [model] ERROR: tRP violation during Activate to bank # |
| ecc | pass | 10/10 | all runs pass |  |
| ecc_fi1 | fail | 2/10 | fault caught by 8/10 runs | [tb] ERROR [ECC_DETECT] double error not detected: sbe=# dbe=# |
| ecc_fi2 | fail | 2/10 | fault caught by 8/10 runs | [tb] ERROR [ECC_FLAG] flags on a clean word: sbe=# dbe=# |
| codec | pass | 1/1 | all runs pass |  |
| codec_fi1 | fail | 0/1 | fault caught by 1/1 runs | [tb] ERROR [ECC_DOUBLE] bits #,# flipped: sbe=# dbe=# |
| codec_fi2 | fail | 0/1 | fault caught by 1/1 runs | [tb] ERROR [ECC_CLEAN] clean word ffffffffffffffffffffffffffffff decoded wrong (sbe=# dbe=#) |
| selftest | pass | 1/1 | all runs pass |  |