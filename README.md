# SQL Server Index Audit
> **Architecture Master Plan · Week C1300S2**  
> From SQL Server DBA to Data Architect | STN Government System Case Study

---

## Overview

This repository documents a hands-on deep dive into SQL Server indexing strategy using a simulated **STN (Sistema Tributario Nacional)** - a high-volume government system processing 1.5M+ tax declarations. The goal is not just to understand indexes theoretically, but to apply them in the context of a real legacy system and draw architectural conclusions.

**System context:** STN is simulated on SQL Server 2022 lab environment. The lab replicates the scale and structure of a real high-volume tax system to practice architecture, diagnosis, and optimization decisions.

---

## Problem Statement

In high-volume transactional systems like STN, unaudited indexes lead to:

- Full clustered scans on every filtered query regardless of result set size
- Non-Clustered indexes ignored by the optimizer due to low column selectivity
- Key Lookups and RID Lookups consuming 89%+ of query cost after seek
- Heap tables forcing RID Lookups with no B-tree navigation guarantee

Without a structured indexing strategy, the optimizer is left to choose between bad options - and it always chooses correctly given what exists.

---

## What's Covered

| Script | Topic |
|--------|-------|
| `01_clustered_vs_nonclustered.sql` | Clustered vs NC - seeks, scans, Key Lookups, RID Lookups |
| `02_covered_indexes.sql` | INCLUDE columns - eliminating Key Lookup and RID Lookup |
| `03_filtered_indexes.sql` | Filtered indexes - minority value strategy, size vs performance |
| `04_composite_indexes_column_order.sql` | Column order - leading key rule, equality before range |
| `05_seek_vs_scan_impact.sql` | Tipping point - when the optimizer abandons the index |
| `06_missing_index_dmvs.sql` | Missing index DMVs - signal vs prescription |
| `07_duplicate_redundant_indexes.sql` | Duplicate detection - write overhead quantification |
| `08_fill_factor_fragmentation.sql` | Fill factor and fragmentation - REORGANIZE vs REBUILD |

---

## Key Concepts Demonstrated

### Real Index Structure - STN Lab

```
Contribuyente (200K rows):
  index_id 1 : PK_Contribuyente     CLUSTERED    - ContribuyenteID (int)
  index_id 2 : IX_Contribuyente_NIT NONCLUSTERED - NIT

Declaracion (1.55M rows):
  index_id 0 : (heap)                        HEAP         - no clustered index
  index_id 2 : PK_Declaracion               NONCLUSTERED - DeclaracionID
  index_id 5 : IX_Declaracion_Contribuyente NONCLUSTERED - ContribuyenteID
```

### Validated Results - STN Lab

**Clustered Index Seek by primary key:**
```
Operator : Clustered Index Seek [PK_Contribuyente]
Reads    : 2  |  Rows: 1  |  Key Lookup: none
```

**Optimizer ignoring NC index - low selectivity (Estado):**
```
Estado = 'A'  (188K rows - 94%) : Index Scan  - scan cheaper than 188K lookups
Estado = 'B'  (  2K rows -  1%) : Index Seek  - lookup cost justified
Estado = 'S'  (columns inside index only) : Index Seek, no Key Lookup
```

**RID Lookup on heap (Declaracion) - before and after INCLUDE:**
```
Before : Index Seek + RID Lookup - reads: 12  |  RID Lookup cost: 89%
After  : Index Seek only         - reads:  3  |  Reduction: 4x
```

**Filtered index vs full NC index (Estado = 'S'):**
```
Full NC index  : 8,632 KB - 200K rows - reads: 15
Filtered index :   104 KB -   2K rows - reads: 13
Size reduction : 98.8%
```

**Composite index - leading column rule:**
```
ContribuyenteID + PeriodoFiscal (both) : Index Seek  - reads: 5
PeriodoFiscal only (second column)     : Table Scan  - reads: 13,852
```

**Tipping point - seek abandonment:**
```
Any range on Contribuyente : Clustered Index Scan - reads: 536
Tipping point before 0.5%. Cause: NIT + RazonSocial outside the key forces lookup at any volume.
```

---

## Architectural Conclusions

**Selectivity determines whether a Non-Clustered index is used.**
At 94% for `Estado = 'A'`, the scan is cheaper - and the optimizer is right.

**A Non-Clustered index only produces Index Seek when the query resolves without leaving the index.**
The solution is not to force a Seek - it is to eliminate the Lookup with INCLUDE columns.

**Heap tables replace Key Lookups with RID Lookups.**
`Declaracion` being a heap is a design decision with ongoing cost at 1.55M rows.

**Column order in composite indexes is the access path.**
Equality predicates must precede range predicates or the B-tree stops navigating.

---

## How to Use This Repository
```bash
# 1. Execute scripts in order with Actual Execution Plan enabled (Ctrl+M in SSMS)
# 2. Run SET STATISTICS IO ON before each section to capture logical reads
# 3. Record operator type and logical reads in each OBSERVATION block
```

**Requirements:** SQL Server 2022 · SSMS 19+ · STN_Lab database (see C1300S1 setup)

---

## About This Repository

This repository is part of a structured architecture practice program focused on SQL Server internals, performance diagnosis, and cloud migration patterns. All systems used (STN, GOVCORE, ENERGRID, TRANSTRACK, LEXNOVA) are simulated legacy environments designed to practice real-world architecture, diagnosis, and modernization decisions at scale.

---

*One step at a time*
