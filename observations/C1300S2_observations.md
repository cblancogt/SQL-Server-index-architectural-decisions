# Observations Document - C1300S2
### Architecture Master Plan 2026–2027 | DBA - Data & Solutions Architect

**Date:** 19 April 2026
**System:** STN - Sistema Tributario Nacional (Government)
**Environment:** SQL Server 2022 · STN_Lab
**Block:** DATA ARCHITECTURE

---

## 1. Context

STN is a high-volume government tax system simulation running on SQL Server 2022 lab environment.
This week's focus — Index Strategy — builds directly on S1 execution plan analysis. The premise: plans revealed the symptoms. Indexes are the structural decisions that eliminate them.

In systems where data integrity and availability are legal requirements, index strategy is not an optimization layer — it is part of the schema design. Every index decision carries a read benefit and a write cost. Both must be documented.

**Lab volumes:**

| Table | Records |
|-------|---------|
| Contribuyente | 200,000 |
| Declaracion | 1,550,000 |
| Pago | 1,200,000 |
| AuditoriaFiscal | 50,000 |

---

## 2. What to Learn

- Understand the structural difference between Clustered and Non-Clustered indexes at the B-tree level
- Identify when a Key Lookup and RID Lookup occur and how to eliminate them
- Apply filtered indexes to minority-value query patterns
- Apply composite index column ordering rules (equality before range, leading key)
- Use missing index DMVs as signals, not prescriptions
- Detect duplicate and redundant indexes with quantified write overhead
- Analyze fragmentation and document fill factor decisions

---

## 3. Applications & Results

### 3.1 Clustered vs Non-Clustered — Index Seek Taxonomy

**Setup:** STN_Lab · dbo.Contribuyente · 200,000 rows

**Executed:** Script 01 — sections 1.0 through 1.8

**Observed:**

| Scenario | Operator | Logical Reads | Notes |
|----------|----------|---------------|-------|
| Seek by ContribuyenteID (clustered key) | Clustered Index Seek | 2 | Leaf level contains full row — no Lookup possible |
| Seek by NIT (NC index, only NIT) | Index Seek (NC) | 3 | NIT covered — no additional columns needed |
| Seek by NIT + columns outside index | Index Seek + Key Lookup | 6 | RazonSocial, Estado outside NC — return trip to clustered |
| Filter by Estado = 'A' (94% of rows) | Index Scan (NC) | ~1,302 (table scan equivalent) | Optimizer ignores Seek — Key Lookup cost per row exceeds scan |
| Filter by Estado = 'B' (1% of rows) | Index Seek (NC) | low | Optimizer uses NC — Lookup cost is justified |
| Filter by Estado = 'S' (covering columns only) | Index Seek (NC) | low | No Key Lookup — both columns inside NC |
| Declaracion heap — ContribuyenteID filter | Index Seek + RID Lookup | 12 | RID Lookup cost 89% of total plan |
| Heap forced full read WITH (INDEX=0) | Table Scan | 13,852 | No B-tree — raw page scan |

**Key finding:**
The optimizer does not use a Non-Clustered index because it exists. It uses it when the cost of Key Lookups per matched row is lower than the cost of reading all pages. At 94% selectivity for `Estado = 'A'`, the full scan is cheaper — and the optimizer is correct. The fix is not to force the Seek; it is to eliminate the Lookup with `INCLUDE` columns.

RID Lookup on `Declaracion` (heap) is structurally more expensive than Key Lookup on a clustered table. A Key Lookup navigates a B-tree with logarithmic depth. A RID Lookup uses a raw physical address (file + page + slot) with no ordering guarantee and higher fragmentation risk over time.

---

### 3.2 Covered Indexes — Eliminating Lookups

**Setup:** STN_Lab · dbo.Contribuyente and dbo.Declaracion

**Executed:** Script 02 — sections 2.0 through 2.8

**Observed:**

| Scenario | Before INCLUDE | After INCLUDE | Reduction |
|----------|---------------|---------------|-----------|
| Contribuyente — NIT seek with RazonSocial, Estado | Index Seek + Key Lookup · reads: 6 | Index Seek only · reads: 3 | 2x reads eliminated |
| Declaracion — ContribuyenteID seek + RID Lookup | Index Seek + RID Lookup · reads: 12 | Index Seek only · reads: 3 | 4x reads eliminated |

**Coverage breakdown:**

| Index | Key Columns | Included Columns | Coverage |
|-------|-------------|------------------|----------|
| IX_Contribuyente_NIT | NIT | — | Narrow — any column beyond NIT triggers Key Lookup |
| IX_Contribuyente_NIT_Cobertor | NIT | RazonSocial, Estado, ContribuyenteID | Full coverage for query pattern |
| IX_Declaracion_ContribuyenteID | ContribuyenteID | — | Narrow — triggers RID Lookup on heap |
| IX_Declaracion_Contribuyente_Cubierto | ContribuyenteID | PeriodoFiscal, MontoDeclarado, Estado, DeclaracionID | Full coverage — RID Lookup eliminated |

**Size comparison:**

| Index | Size (KB) | Row Count |
|-------|-----------|-----------|
| IX_Contribuyente_NIT | 4,312 | 200,000 |
| IX_Contribuyente_NIT_Cobertor | 8,760 | 200,000 |
| IX_Declaracion_ContribuyenteID | 68,208 | 1,550,000 |
| IX_Declaracion_Contribuyente_Cobertor | 61,712 | 1,550,000 |

**Key finding:**
Coverage is query-specific, not table-wide. Adding one column outside the INCLUDE list re-introduces the Key Lookup (validated in section 2.4 with `TipoPersona`). INCLUDE columns exist only at the leaf level — they cannot be used as predicates in WHERE. If a column must filter AND be returned, it must be a key column in the index.

The storage cost of covering indexes is acceptable when measured against the I/O reduction. Cobertor on Declaracion is actually smaller than the bare NC index because INCLUDE columns are stored only at the leaf and do not replicate through intermediate B-tree levels.

---

### 3.3 Filtered Indexes — Minority Value Strategy

**Setup:** STN_Lab · dbo.Contribuyente · Estado distribution: A=94%, I=5%, S=1%

**Executed:** Script 03 — sections 3.0 through 3.7

**Observed — Estado distribution:**

| Estado | Rows | Percentage |
|--------|------|------------|
| A | 188,000 | 94% |
| I | 10,000 | 5% |
| S | 2,000 | 1% |

**Index size comparison:**

| Index | Size (KB) | Row Count | Notes |
|-------|-----------|-----------|-------|
| IX_Contribuyente_Estado_Full | 8,632 | 200,000 | Full NC on Estado with INCLUDE |
| IX_Contribuyente_Estado_Filtrado | 104 | 2,000 | Filtered: WHERE Estado = 'S' |

**Query performance (forcing each index):**

| Scenario | Logical Reads | Operator |
|----------|---------------|----------|
| Full NC — Estado = 'S' | 15 | Index Seek |
| Filtered index — Estado = 'S' | 13 | Index Seek |
| Without hint — Estado = 'S' | 13 | Index Seek (filtered chosen automatically) |

**Key finding:**
A filtered index over `Estado = 'S'` is 98.8% smaller than a full NC index on the same column. It contains only 2,000 rows instead of 200,000. Size reduction directly impacts buffer pool consumption and fragmentation rate. The optimizer selected the filtered index automatically without hints when the predicate matched exactly.

Critical limitation: the filtered index is only eligible when the query predicate matches the filter exactly. Dynamic parameters or parameterized queries may prevent the optimizer from using a filtered index if parameter sniffing cannot resolve the match at compile time.

---

### 3.4 Composite Indexes — Column Order as Access Path

**Setup:** STN_Lab · dbo.Declaracion · 1,550,000 rows

**Executed:** Script 04 — sections 4.0 through 4.6

**Observed — leading key rule:**

| Query Predicate | Index Used | Operator | Logical Reads |
|----------------|------------|----------|---------------|
| ContribuyenteID + PeriodoFiscal (both columns) | IX_Declaracion_Contribuyente_Periodo | Index Seek | 5 |
| PeriodoFiscal only (second column, no lead) | — | Table Scan | 13,852 |

**Observed — equality vs range ordering:**

| Column Order | Query Filter | Logical Reads | Rows Returned |
|-------------|-------------|---------------|---------------|
| Estado (equality) → FechaPresentacion (range) | Estado = 'PR' AND FechaPresentacion >= '2020-01-03' | 13,852 | 1,157,400 |
| FechaPresentacion (range) → Estado (equality) | Estado = 'P' AND FechaPresentacion >= '2023-01-01' | 3,724 | 50,000 |

**Index size comparison (all at 1,550,000 rows):**

| Index | Size (KB) |
|-------|-----------|
| IX_Declaracion_Contribuyente_Periodo | 55,640 |
| IX_Declaracion_Estado_Fecha | 55,560 |
| IX_Declaracion_Fecha_Estado | 55,672 |
| IX_Declaracion_Periodo_Contribuyente | 55,696 |

**Key finding:**
Column order in a composite index is the access path. The B-tree is sorted left to right. A query filtering only on the second column forces a full index scan — the optimizer cannot navigate to an intermediate sort position without the leading key.

Equality predicates must precede range predicates. A range predicate (BETWEEN, >, <, >=) stops the B-tree from using subsequent key columns for navigation. Placing the range column first collapses all subsequent equality predicates into a post-filter operation, dramatically increasing row reads.

The practical rule: sort columns in composite indexes by (1) equality predicates ordered by selectivity, then (2) range predicates. The RID Lookup on `DeclaracionID` in section 4.1 (cost 64%) signals that `DeclaracionID` should be added to INCLUDE when the query requires it.

---

### 3.5 Seek vs Scan — Tipping Point Analysis

**Setup:** STN_Lab · dbo.Contribuyente · Clustered Index on ContribuyenteID

**Executed:** Script 05 — sections 5.1 through 5.5

**Observed:**

| Range | Rows | Operator | Reads |
|-------|------|----------|-------|
| ContribuyenteID = 500 (1 row) | 1 | Clustered Index Seek | 3 |
| ContribuyenteID > 0 (all rows) | 199,880 | Clustered Index Seek (range) | 1,314 |
| BETWEEN 1 AND 1,000 (0.5%) | 1,000 | Clustered Index Scan | 536 |
| BETWEEN 1 AND 10,000 (5%) | 10,000 | Clustered Index Scan | 536 |
| BETWEEN 1 AND 30,000 (15%) | 30,000 | Clustered Index Scan | 536 |
| BETWEEN 1 AND 60,000 (30%) | 60,000 | Clustered Index Scan | 536 |

**Declaracion Seek vs full Scan ratio:**

| Scenario | Reads | Notes |
|----------|-------|-------|
| ContribuyenteID = 500 (NC Seek + RID Lookup) | 12 | Index Seek on NC |
| Full table scan (WITH INDEX = 0) | 13,852 | Raw heap read |
| Ratio | 1,154x | Seek advantage at single-contributor scale |

**Key finding:**
The tipping point occurred before the 0.5% threshold on `Contribuyente`. The reads were identical across all four range sizes (536) because the optimizer calculated that reading all data pages was cheaper than Seek + Key Lookup for `NIT` and `RazonSocial` outside the key. This is the tipping point in practice: it is not about row count alone — it is about row count multiplied by Key Lookup cost per row.

With a covering index, the tipping point would shift significantly. The current behavior is a function of missing INCLUDE columns, not of the selectivity threshold alone.

---

### 3.6 Missing Index DMVs — Signal vs Prescription

**Setup:** STN_Lab — cold DMVs, then seeded with queries on DepartamentoID, TipoPersona, FechaPresentacion, TipoImpuestoID, Estado + PeriodoFiscal

**Executed:** Script 06 — sections 6.0 through 6.5

**Observed — DMV recommendations (post-seed):**

| Table | Equality Columns | Inequality Columns | Included Columns | Impact % | Priority Score |
|-------|-----------------|-------------------|------------------|----------|----------------|
| Declaracion | TipoImpuestoID | FechaPresentacion | DeclaracionID, ContribuyenteID, PeriodoFiscal, MontoImpuesto | 89.4 | 9.91 |
| Contribuyente | TipoPersona, DepartamentoID | — | NIT, RazonSocial | 90.3 | 1.23 |

**Before/after implementing top recommendation (Declaracion):**

| Scenario | Operator | Reads |
|----------|----------|-------|
| Before index: FechaPresentacion + TipoImpuestoID | Table Scan (parallel) | high |
| After IX_Declaracion_Fecha_TipoImpuesto | Index Seek (NC) | low |

**DMV uptime check:**

| Field | Value |
|-------|-------|
| sqlserver_start_time | 2026-04-19 08:15:25.957 |

**Key finding:**
Missing index DMVs reset on every service restart. Data is only as reliable as the uptime since the last restart. A high priority score in a lab environment may represent a single seeded query, not production frequency.

The DMV suggestion for `Declaracion` used the pattern: equality column first (TipoImpuestoID), range column second (FechaPresentacion). This is the correct composite order — it directly validates the rule from section 3.4. The suggested index was implemented and the plan shifted from Table Scan to Index Seek.

DMV recommendations are signals, not prescriptions. Each recommendation requires validation against: (1) actual query frequency in production, (2) overlap with existing indexes, (3) write overhead on the affected table.

---

### 3.7 Duplicate and Redundant Indexes — Write Overhead Quantification

**Setup:** STN_Lab — IX_Declaracion_ContribuyenteID_Dup created explicitly for exercise

**Executed:** Script 07 — sections 7.0 through 7.5

**Observed — exact duplicate detected:**

| Table | Index 1 | Index 2 | Key Columns |
|-------|---------|---------|-------------|
| Declaracion | IX_Declaracion_ContribuyenteID | IX_Declaracion_ContribuyenteID_Dup | ContribuyenteID |

**Observed — redundant indexes (prefix overlap):**

| Table | Redundant Index | Covered By | Redundant Columns | Covering Columns |
|-------|----------------|------------|-------------------|-----------------|
| Declaracion | IX_Declaracion_ContribuyenteID | IX_Declaracion_Contribuyente_Periodo | ContribuyenteID | ContribuyenteID, PeriodoFiscal |
| Declaracion | IX_Declaracion_ContribuyenteID | IX_Declaracion_ContribuyenteID_Dup | ContribuyenteID | ContribuyenteID |
| Declaracion | IX_Declaracion_ContribuyenteID_Dup | IX_Declaracion_Contribuyente_Periodo | ContribuyenteID | ContribuyenteID, PeriodoFiscal |
| Declaracion | IX_Declaracion_ContribuyenteID_Dup | IX_Declaracion_ContribuyenteID | ContribuyenteID | ContribuyenteID |

**Observed — write overhead by index (post-lab session, DMV since restart):**

| Table | Index | User Seeks | User Scans | User Updates | Evaluation |
|-------|-------|-----------|-----------|--------------|------------|
| Contribuyente | IX_Contribuyente_NIT | 0 | 0 | 0 | Solo escritura — candidato a eliminar |
| Declaracion | IX_Declaracion_ContribuyenteID | 0 | 0 | 0 | Solo escritura — candidato a eliminar |
| Declaracion | IX_Declaracion_Fecha_Estado | 0 | 0 | 0 | Solo escritura — candidato a eliminar |
| Declaracion | IX_Declaracion_Estado_Fecha | 0 | 0 | 0 | Solo escritura — candidato a eliminar |
| Declaracion | IX_Declaracion_ContribuyenteID_Dup | 0 | 0 | 0 | Solo escritura — candidato a eliminar |
| Declaracion | IX_Declaracion_Contribuyente_Periodo | 1 | 0 | 0 | Balance aceptable |
| Declaracion | IX_Declaracion_Periodo_Contribuyente | 2 | 0 | 0 | Balance aceptable |

**Key finding:**
Every duplicate index adds write overhead to INSERT, UPDATE, and DELETE with no read benefit. In a table like `Declaracion` with 1,550,000 rows and high nightly insert volume (as demonstrated in S1 with the 50,000-row bulk insert), duplicate indexes compound fragmentation and maintenance windows.

The zero user_seeks / user_scans values in this session reflect lab conditions (short DMV uptime since restart). In production, this query must be run against DMVs with days or weeks of accumulated data before drawing elimination conclusions.

The safe elimination rule: an index is a candidate for removal when (1) a longer composite index already covers its leading columns, and (2) DMV data over sufficient time shows reads at or near zero.

---

### 3.8 Fill Factor and Fragmentation — Maintenance Decision Framework

**Setup:** STN_Lab — all tables, sampled fragmentation analysis

**Executed:** Script 08 — sections 8.0 through 8.4

**Observed — fragmentation baseline (post-lab session):**

| Table | Index | Avg Fragmentation % | Page Count | Action |
|-------|-------|---------------------|-----------|--------|
| Contribuyente | IX_Contribuyente_NIT | 1.34 | 524 | Sin acción |
| Contribuyente | PK_Contribuyente | 0.54 | 1,307 | Sin acción |
| Declaracion | PK_Declaracion | 0.23 | 3,456 | Sin acción |
| Declaracion | IX_Declaracion_ContribuyenteID | 0.23 | 3,456 | Sin acción |
| Declaracion | IX_Declaracion_Fecha_Estado | 0.20 | 6,924 | Sin acción |
| Declaracion | IX_Declaracion_Contribuyente_Periodo | 0.10 | 6,921 | Sin acción |

**After REORGANIZE on IX_Contribuyente_NIT:**

| Metric | Before | After |
|--------|--------|-------|
| avg_fragmentation_in_percent | 1.34 | 0.95 |
| page_count | 524 | 524 |

**Fill factor validation — IX_Declaracion_ContribuyenteID:**

| Metric | Value |
|--------|-------|
| fill_factor applied | 80 |
| avg_fragmentation_in_percent post-REBUILD | 0.35 |
| avg_page_space_used_in_percent | 79.91 |

**Decision framework validated:**

| Fragmentation Range | Action | Notes |
|--------------------|--------|-------|
| < 5% | No action | Cost of maintenance exceeds benefit |
| 5% – 30% | REORGANIZE | Online operation, leaf level only, no statistics update |
| > 30% | REBUILD | Full recreation, offline capable, statistics updated automatically |

**Key finding:**
Lab data shows near-zero fragmentation because the dataset was loaded sequentially with no random-key inserts. In production with STN's nightly bulk insert pattern and concurrent transactional updates (declarations per contributor are non-sequential), fragmentation on `Declaracion` would accumulate faster on indexes with non-sequential key values like `NIT` (VARCHAR) or composite indexes with date ranges.

Fill factor of 80 on `IX_Declaracion_ContribuyenteID` leaves 20% free space per page at REBUILD time — reducing page splits during subsequent inserts. The trade-off is a 25% increase in page count and proportional increase in reads for full scans. Fill factor is a write-pattern decision, not a global setting: sequential-key inserts (identity columns) tolerate 100%; random or date-based keys benefit from 70–85%.

The maintenance script generated in section 8.4 produces executable ALTER INDEX statements per index, pre-classified by the REORGANIZE/REBUILD threshold. This is the foundation for the weekly maintenance job on STN.

---

## 4. SQL Server 2022 — Feature Observations

| Feature | Behavior | Observed |
|---------|----------|----------|
| Missing Index DMV integration in execution plan | Missing Index hint appears inline in the plan header when a query has no suitable index | YES — visible in scripts 04 and 06 |
| Adaptive Join | Plan chose between Nested Loops and Hash Match at runtime based on actual row count | YES — on Declaracion joins |
| Batch Mode on Rowstore | Aggregation queries on Declaracion used Batch execution mode | YES |
| Parallel plan activation | Table Scan on 1.55M rows triggered Gather Streams on MAXDOP 8 config | YES — scripts 04 and 05 |

---

## 5. Architectural Conclusions

### Problem this topic solves

Index strategy in STN is not an optimization exercise — it is a diagnostic discipline. The execution plans from S1 identified Key Lookups, RID Lookups, and Table Scans as the structural causes of performance degradation. This week's work quantifies the solutions and their trade-offs.

Without structured index analysis, every performance incident leads to one of three incorrect responses: adding a new index without checking existing coverage, adding server resources to compensate for avoidable I/O, or tuning individual queries without addressing the underlying access pattern.

### Architectural decisions taken

**Decision 1:** Establish covered index design as the default pattern for all NC indexes in STN — INCLUDE columns are not optional; they are determined by the query pattern before the index is created.

**Context:** `Declaracion` at 1.55M rows with heap structure generates RID Lookups on every multi-column query. Key Lookups on `Contribuyente` generate return trips to the clustered index on every NIT-based lookup that requests more than one column.

**Rationale:** A 4x read reduction on a 1.55M-row table accessed by reporting queries that run concurrently with transactional inserts is not a marginal improvement — it is the difference between a query that completes in milliseconds and one that competes for buffer pool pages under load.

**Consequences:** INCLUDE columns increase index size at the leaf level. Index maintenance windows must account for the larger structure. New query patterns that require columns outside the INCLUDE list must be evaluated before adding them — each addition is permanent until the index is rebuilt.

---

**Decision 2:** Apply filtered indexes for minority-value query patterns in STN (Estado = 'S', suspended contributors) — not full NC indexes on low-selectivity columns.

**Context:** `Estado` in `Contribuyente` has three values: A (94%), I (5%), S (1%). A full NC index on `Estado` with INCLUDE consumes 8,632 KB for 200,000 rows. A filtered index for Estado = 'S' consumes 104 KB for 2,000 rows.

**Rationale:** 98.8% size reduction with equivalent seek performance for the target predicate. Buffer pool pressure from large NC indexes on low-selectivity columns is a recurring pattern in legacy government systems that accumulated indexes without auditing them.

**Consequences:** Filtered indexes require exact predicate match. Parameterized queries must use literal values or SET ANSI_NULLS/ANSI_PADDING settings that allow the optimizer to match the filter. Dynamic SQL with parameterized Estado values may bypass the filtered index.

---

**Decision 3:** Establish a quarterly index audit process for STN based on DMV data — combining sys.dm_db_missing_index_group_stats (signals), sys.dm_db_index_usage_stats (write overhead), and sys.dm_db_index_physical_stats (fragmentation).

**Context:** The lab session identified one exact duplicate (IX_Declaracion_ContribuyenteID_Dup), four redundant prefix overlaps, and five indexes with zero read activity since the last service restart. In a production environment with months of DMV data, this pattern would identify candidates for removal with quantified write overhead savings.

**Rationale:** Indexes that are never read but always written to are a tax on every INSERT, UPDATE, and DELETE on the table. On `Declaracion` with nightly bulk inserts of 50,000+ rows, each unnecessary index multiplies the maintenance cost of those operations.

**Consequences:** Quarterly cadence requires DMV data continuity — service restarts reset the counters. Production audit must account for uptime and seasonal patterns (e.g., tax declaration peaks in December).

---

### How this would be explained in an interview

"In high-volume tax systems like STN, index strategy is the single highest-leverage architectural decision below the data model itself. The patterns are predictable: Key Lookups from narrow NC indexes, RID Lookups from heap tables, full scans from low-selectivity columns, and composite indexes built in the wrong column order. Each one is diagnosable from the execution plan and fixable with a precise structural change. In the STN lab, adding INCLUDE columns eliminated a 4x I/O difference on Declaracion, a filtered index reduced storage by 98.8% for a minority-value pattern, and composite column ordering changed a 13,852-read scan into a 5-read seek. None of these required query changes, application changes, or hardware."

---

## 6. What's Next

**This feeds into:**
- C1300S3: Motor Interno — Buffer Pool, Plan Cache, Memory Grants — indexes interact directly with buffer pool consumption and plan cache behavior
- C1300S8: Cargas Masivas y Particionamiento — fill factor decisions and index maintenance strategies for bulk-insert workloads
- C1300S11: Columnstore / HTAP — the analytical queries on STN that currently force Table Scans on 1.55M rows are the target use case for columnstore

---

## 7. References & Resources

- **GitHub repo:** https://github.com/cblancogt/sql-server-index-audit
- **Scripts executed:** 01_clustered_vs_nonclustered.sql · 02_covered_indexes.sql · 03_filtered_indexes.sql · 04_composite_indexes_column_order.sql · 05_seek_vs_scan_impact.sql · 06_missing_index_dmvs.sql · 07_duplicate_redundant_indexes.sql · 08_fill_factor_fragmentation.sql
- **Prior session:** C1300S1_observations.md — Execution Plans Deep Dive (foundation for this week's index decisions)

---
