# SQL Server Index Audit
> **Architecture Master Plan · Week C1300S2**  
> From SQL Server DBA to Data Architect | STN Government System Case Study

---

## Overview

This repository documents a hands-on deep dive into SQL Server indexing strategy using a simulated **STN (Sistema Tributario Nacional)** — a high-volume government system processing 1.5M+ tax declarations. The goal is not to understand indexes theoretically, but to apply them in the context of a real legacy system and document architectural decisions with measurable outcomes.

**System context:** STN is simulated on SQL Server 2022 lab environment. The lab replicates the scale and structure of a real high-volume tax system to practice architecture, diagnosis, and optimization decisions.

**Prerequisite:** This week builds directly on [sql-server-execution-plans-deep-dive](https://github.com/cblancogt/sql-server-execution-plans-deep-dive) (C1300S1). Plans revealed the symptoms. Indexes are the structural decisions that eliminate them.

---

## Problem Statement

In high-volume transactional systems like STN, unaudited indexes lead to:

- Full clustered scans on every filtered query regardless of result set size
- Non-Clustered indexes ignored by the optimizer due to low column selectivity
- Key Lookups and RID Lookups consuming 89%+ of query cost after seek
- Heap tables forcing RID Lookups with no B-tree navigation guarantee
- Redundant and duplicate indexes adding write overhead on every INSERT, UPDATE, and DELETE with no read benefit

Without a structured indexing strategy, the optimizer is left to choose between bad options — and it always chooses correctly given what exists. The problem is what exists.

---

## What's Covered

| Script | Topic |
|--------|-------|
| `01_clustered_vs_nonclustered.sql` | Clustered vs NC — seeks, scans, Key Lookups, RID Lookups |
| `02_covered_indexes.sql` | INCLUDE columns — eliminating Key Lookup and RID Lookup |
| `03_filtered_indexes.sql` | Filtered indexes — minority value strategy, size vs performance |
| `04_composite_indexes_column_order.sql` | Column order — leading key rule, equality before range |
| `05_seek_vs_scan_impact.sql` | Tipping point analysis — when the optimizer abandons the index |
| `06_missing_index_dmvs.sql` | Missing index DMVs — signal vs prescription |
| `07_duplicate_redundant_indexes.sql` | Duplicate and redundant index detection — write overhead quantification |
| `08_fill_factor_fragmentation.sql` | Fill factor and fragmentation — REORGANIZE vs REBUILD decision |

---

## Key Concepts Demonstrated

### Real Index Structure — STN Lab

```
Contribuyente (200K rows):
  index_id 1 : PK_Contribuyente              CLUSTERED     - ContribuyenteID (int)
  index_id 2 : IX_Contribuyente_NIT          NONCLUSTERED  - NIT
  index_id 4 : IX_Contribuyente_NIT_Cobertor NONCLUSTERED  - NIT | INCLUDE: RazonSocial, Estado, ContribuyenteID

Declaracion (1.55M rows):
  index_id 0 : (heap)                                HEAP          - no clustered index
  index_id 2 : PK_Declaracion                        NONCLUSTERED  - DeclaracionID
  index_id 5 : IX_Declaracion_ContribuyenteID        NONCLUSTERED  - ContribuyenteID
  index_id 6 : IX_Declaracion_Contribuyente_Periodo  NONCLUSTERED  - ContribuyenteID, PeriodoFiscal | INCLUDE: MontoDeclarado, Estado
```

---

## Validated Results — STN Lab

### Clustered Index Seek by primary key (ContribuyenteID)
```
Operator      : Clustered Index Seek [PK_Contribuyente]
Logical reads : 2
Rows          : 1
Key Lookup    : none — leaf level contains the full row
```

### Non-Clustered Seek by NIT + Key Lookup
```
Operator 1    : Index Seek (NonClustered) [IX_Contribuyente_NIT]
Operator 2    : Key Lookup (Clustered) [PK_Contribuyente]
Join          : Nested Loops (Inner Join)
Logical reads : 6
```

### Covered index eliminates Key Lookup
```
Before INCLUDE : Index Seek + Key Lookup — logical reads: 6
After INCLUDE  : Index Seek only         — logical reads: 3
Reduction      : 2x
```

### Optimizer ignoring NC index — low selectivity (Estado)
```
Estado = 'A'  (188,000 rows — 94%) → Index Scan  — optimizer ignores seek, Key Lookup cost > scan cost
Estado = 'B'  (  2,000 rows —  1%) → Index Seek  — optimizer uses NC, Lookup cost justified
Estado = 'S'  (columns inside index only)         → Index Seek, no Key Lookup
```

### RID Lookup on heap table (Declaracion)
```
Operator 1    : Index Seek (NonClustered) [IX_Declaracion_ContribuyenteID]   Cost: 11%
Operator 2    : RID Lookup (Heap) [Declaracion]                               Cost: 89%
Join          : Nested Loops (Inner Join)
Logical reads : 12
```

### Covered index eliminates RID Lookup (Declaracion)
```
Before INCLUDE : Index Seek + RID Lookup — logical reads: 12
After INCLUDE  : Index Seek only         — logical reads: 3
Reduction      : 4x
```

### Filtered index vs full NC index (Estado = 'S', 2,000 rows)
```
Full NC index    : 8,632 KB — 200,000 rows — reads: 15
Filtered index   :   104 KB —   2,000 rows — reads: 13
Size reduction   : 98.8%
```

### Composite index — leading column rule (Declaracion, 1.55M rows)
```
ContribuyenteID + PeriodoFiscal (both columns, leading key present)  → Index Seek  — reads: 5
PeriodoFiscal only (second column, no leading key)                   → Table Scan  — reads: 13,852
```

### Equality vs range ordering
```
Estado (equality) → FechaPresentacion (range) : reads: 13,852 — rows returned: 1,157,400
FechaPresentacion (range) → Estado (equality) : reads:  3,724 — rows returned:    50,000
```

### Tipping point — seek abandonment
```
Range 1–1,000   (0.5%)  : Clustered Index Scan — reads: 536
Range 1–10,000  (5%)    : Clustered Index Scan — reads: 536
Range 1–30,000  (15%)   : Clustered Index Scan — reads: 536
Range 1–60,000  (30%)   : Clustered Index Scan — reads: 536

Conclusion: tipping point occurred before 0.5%.
Cause: Key Lookup cost for NIT + RazonSocial (outside the key) exceeds full scan cost at any range size.
Fix: covering index with INCLUDE(NIT, RazonSocial).
```

### Fragmentation baseline — post-lab session
```
IX_Contribuyente_NIT          : 1.34% fragmentation — 524 pages  → Sin acción
PK_Contribuyente              : 0.54% fragmentation — 1,307 pages → Sin acción
IX_Declaracion_ContribuyenteID: 0.23% fragmentation — 3,456 pages → Sin acción
```

### Fill factor validation
```
Index   : IX_Declaracion_ContribuyenteID
REBUILD : FILLFACTOR = 80
Result  : avg_fragmentation = 0.35% — avg_page_space_used = 79.91%
```

---

## Architectural Conclusions

**Selectivity determines whether a Non-Clustered index is used.**
The optimizer calculates Key Lookup cost × estimated rows and compares it against a full scan. At 94% selectivity for `Estado = 'A'`, the scan is cheaper — and the optimizer is right. The index is not wrong; the missing INCLUDE columns are wrong.

**A Non-Clustered index only produces Index Seek when the query can be resolved without leaving the index.**
The moment additional columns are requested outside the index, the optimizer re-evaluates. The solution is not to force a Seek — it is to eliminate the Lookup with INCLUDE columns.

**Heap tables replace Key Lookups with RID Lookups.**
A Key Lookup navigates a B-tree — depth is logarithmic and predictable. A RID Lookup uses a raw physical address (file + page + slot) — no ordering guarantee and higher fragmentation risk over time. `Declaracion` being a heap is a design decision with ongoing cost implications at 1.55M rows.

**Filtered indexes trade coverage for size.**
A filtered index over `Estado = 'S'` is 98.8% smaller than a full NC index on the same column. It only works when the query predicate exactly matches the index filter. Dynamic or parameterized queries may prevent the optimizer from selecting it.

**Column order in composite indexes is the access path.**
A query filtering only on the second column forces a full index scan. Equality predicates must precede range predicates or the B-tree stops using subsequent columns for navigation.

**Missing index DMVs reset on service restart.**
Recommendations are proportional to query frequency since the last restart. A high priority score in a lab session may represent a single seeded query. DMV data must be evaluated against uptime and seasonal query patterns before any index is created or dropped.

**Every redundant index is a write tax.**
Duplicate indexes add overhead to every INSERT, UPDATE, and DELETE with zero read benefit. On a 1.55M-row table with nightly bulk inserts, this compounds directly into maintenance window duration and fragmentation rate.

**Fill factor is a write-pattern decision.**
Sequential-key inserts (identity columns) tolerate fill factor 100. Random or date-based keys benefit from 70–85. A fill factor of 80 on `IX_Declaracion_ContribuyenteID` reduced post-load fragmentation to 0.35% with page space utilization at 79.91%.

---

## Fragmentation Decision Framework

| Fragmentation | Action | Notes |
|--------------|--------|-------|
| < 5% | No action | Maintenance cost exceeds benefit |
| 5% – 30% | REORGANIZE | Online, leaf level only, no statistics update |
| > 30% | REBUILD | Full recreation, statistics updated automatically |

---

## How to Use This Repository

```bash
# 1. Execute scripts in order with Actual Execution Plan enabled (Ctrl+M in SSMS)
# 2. Run SET STATISTICS IO ON before each section to capture logical reads
# 3. Record operator type and logical reads in each OBSERVATION block
# 4. Run 07 and 08 after all other scripts to audit the accumulated index state
```

**Requirements:**
- SQL Server 2022
- SSMS 19+
- STN_Lab database (see C1300S1 setup)

---

## Observations Document

Full session observations, measurements, and architectural decisions are documented in:

📄 [`C1300S2_observations.md`](./docs/C1300S2_observations.md)

Prior session: [`C1300S1_observations.md`](https://github.com/cblancogt/sql-server-execution-plans-deep-dive/blob/main/docs/C1300S1_observations.md)

---

## About This Repository

This repository is part of a structured architecture practice program focused on SQL Server internals, performance diagnosis, and cloud migration patterns. All systems used (STN, GOVCORE, ENERGRID, TRANSTRACK, LEXNOVA) are simulated legacy environments designed to practice real-world architecture, diagnosis, and modernization decisions at scale.

---

*One step at a time*
