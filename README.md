# SQL Server Index Audit - architecture
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
|---|---|
| `01_clustered_vs_nonclustered.sql` | Clustered vs NC - seeks, scans, lookups, RID lookups |
| `02_covered_indexes.sql` | INCLUDE columns - eliminating Key Lookup and RID Lookup |
| `03_filtered_indexes.sql` | Filtered indexes - minority value strategy, size vs performance |
| `04_composite_indexes_column_order.sql` | Column order - leading key rule, equality before range |

---

## Key Concepts Demonstrated

### Real Index Structure - STN Lab

```
Contribuyente (200K rows):
  index_id 1 : PK_Contribuyente            CLUSTERED     - ContribuyenteID (int)
  index_id 2 : IX_Contribuyente_NIT        NONCLUSTERED  - NIT
  index_id 4 : IX_Contribuyente_NIT_Covering NONCLUSTERED - NIT (covered)

Declaracion (1.55M rows):
  index_id 0 : (heap)                      HEAP          - no clustered index
  index_id 2 : PK_Declaracion             NONCLUSTERED  - DeclaracionID
  index_id 5 : IX_Declaracion_ContribuyenteID NONCLUSTERED - ContribuyenteID
```

### Validated Results - STN Lab

**Clustered Index Seek by primary key (ContribuyenteID):**
```
Operator      : Clustered Index Seek [PK_Contribuyente]
Logical reads : 2
Rows          : 1
Key Lookup    : none - leaf level contains the full row
```

**Non-Clustered Seek by NIT + Key Lookup:**
```
Operator 1    : Index Seek (NonClustered) [IX_Contribuyente_NIT]
Operator 2    : Key Lookup (Clustered) [PK_Contribuyente]
Join          : Nested Loops (Inner Join)
```

**Optimizer ignoring NC index - low selectivity (Estado):**
```
Estado = 'A'  (188,000 rows - 94%) - Index Scan  - optimizer ignores seek
Estado = 'B'  (  2,000 rows -  1%) - Index Seek  - optimizer uses NC index
Estado = 'S'  (columns inside index only) - Index Seek - no Key Lookup
```

**RID Lookup on heap table (Declaracion):**
```
Operator 1    : Index Seek (NonClustered) [IX_Declaracion_ContribuyenteID]  Cost: 11%
Operator 2    : RID Lookup (Heap) [Declaracion]                              Cost: 89%
Join          : Nested Loops (Inner Join)
Rows          : 9
```

**Covered index eliminates RID Lookup (Declaracion):**
```
Before INCLUDE : Index Seek + RID Lookup - logical reads: 12
After INCLUDE  : Index Seek only         - logical reads: 3
```

**Filtered index vs full NC index (Estado = 'S', 2,000 rows):**
```
Full NC index  : 8,632 KB - 200,000 rows - reads: 15
Filtered index :   104 KB -   2,000 rows - reads: 13
Size reduction : 98.8%
```

**Composite index - leading column rule (Declaracion, 1.55M rows):**
```
ContribuyenteID + PeriodoFiscal (both columns) : Index Seek  - reads: 5
PeriodoFiscal only (second column, no lead)    : Index Scan  - reads: 13,852
Equality first, range second                   : reads: 13,852 - 1,157,400 rows
Range first, equality second                   : reads:  3,724 -    50,000 rows
```

---

## Architectural Conclusions

**Selectivity determines whether a Non-Clustered index is used.**
The optimizer calculates Key Lookup cost x estimated rows and compares it against a full scan. At 94% selectivity for `Estado = 'A'`, the scan is cheaper - and the optimizer is right.

**A Non-Clustered index only produces Index Seek when the query can be resolved without leaving the index.**
The moment additional columns are requested outside the index, the optimizer re-evaluates. The solution is not to force a Seek - it is to eliminate the Lookup with `INCLUDE` columns.

**Heap tables replace Key Lookups with RID Lookups.**
A Key Lookup navigates a B-tree - depth is logarithmic and predictable. A RID Lookup uses a raw physical address (file + page + slot) - no ordering guarantee and higher fragmentation risk over time. `Declaracion` being a heap is a design decision with ongoing cost implications at 1.55M rows.

**Filtered indexes trade coverage for size.**
A filtered index over `Estado = 'S'` is 98.8% smaller than a full NC index on the same column. It only works when the query predicate exactly matches the index filter.

**Column order in composite indexes is the access path.**
A query filtering only on the second column forces a full index scan. Equality predicates must precede range predicates or the B-tree stops using subsequent columns for navigation.

---

## How to Use This Repository
```bash
# 1. Execute scripts in order with Actual Execution Plan enabled (Ctrl+M in SSMS)
# 2. Run SET STATISTICS IO ON before each section to capture logical reads
# 3. Record operator type and logical reads in each OBSERVATION block
```

**Requirements:**
- SQL Server 2022
- SSMS 19+
- STN_Lab database (see C1300S1 setup)

---

## About This Repository

This repository is part of a structured architecture practice program focused on SQL Server internals, performance diagnosis, and cloud migration patterns. All systems used (STN, GOVCORE, ENERGRID, TRANSTRACK, LEXNOVA) are simulated legacy environments designed to practice real-world architecture, diagnosis, and modernization decisions at scale.

---

*One step at a time*
