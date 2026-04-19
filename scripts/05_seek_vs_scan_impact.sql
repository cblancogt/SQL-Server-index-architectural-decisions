-- ============================================================
-- C1300S2 | sql-server-index-audit
-- File   : 05_seek_vs_scan_impact.sql
-- Topic  : Index Seek vs Scan -- Real Impact at Scale
-- System : STN_Lab -- Sistema Tributario Nacional (Lab)
-- Author : Carlos Roberto C13
-- ============================================================
-- PURPOSE
-- Quantify the real cost difference between Index Seek and
-- Index Scan using SET STATISTICS IO. Demonstrate that the
-- gap between Seek and Scan grows with table size, and that
-- the optimizer threshold for choosing Scan over Seek depends
-- on estimated row count.
-- ============================================================

USE STN_Lab;
GO

-- ============================================================
-- 5.0 -- ENVIRONMENT CHECK
-- ============================================================

SELECT
    t.name          AS table_name,
    i.type_desc     AS index_type,
    s.row_count,
    s.used_page_count * 8 AS size_kb
FROM sys.tables t
JOIN sys.indexes i
    ON t.object_id = i.object_id
JOIN sys.dm_db_partition_stats s
    ON i.object_id = s.object_id
   AND i.index_id  = s.index_id
WHERE t.name IN ('Contribuyente', 'Declaracion')
  AND i.index_id IN (0, 1)
ORDER BY t.name;


-- ============================================================
-- 5.1 -- CONTROLLED SEEK: ONE ROW
-- Seek cost is logarithmic -- depth of B-tree only.
-- Reads should be 2-4 regardless of table size.
-- ============================================================

SET STATISTICS IO ON;
SET STATISTICS TIME ON;

SELECT ContribuyenteID, NIT, RazonSocial, Estado
FROM dbo.Contribuyente
WHERE ContribuyenteID = 500;

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-- OBSERVACION 5.1
-- reads_5.1 = _3__   (Clustered Index Seek -- 1 row)


-- ============================================================
-- 5.2 -- CONTROLLED SCAN: ALL ROWS
-- Full scan reads every page regardless of filter.
-- ============================================================

SET STATISTICS IO ON;
SET STATISTICS TIME ON;

SELECT ContribuyenteID, NIT, RazonSocial, Estado
FROM dbo.Contribuyente
WHERE ContribuyenteID > 0;

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-- OBSERVACION 5.2
-- reads_5.2 = 1314   (Clustered Index Scan all rows)
-- Ratio seek/scan = reads_5.2 / reads_5.1 = 438


-- ============================================================
-- 5.3 -- THE TIPPING POINT
-- Find the approximate row count at which the optimizer
-- switches from Seek to Scan on Contribuyente.
-- Record operator and logical reads for each range.
-- ============================================================

-- 5.3.1 -- 0.5% of rows (1,000 rows)
SET STATISTICS IO ON;
SELECT ContribuyenteID, NIT, RazonSocial
FROM dbo.Contribuyente
WHERE ContribuyenteID BETWEEN 1 AND 1000;
SET STATISTICS IO OFF;
GO

-- 5.3.2 -- 5% of rows (10,000 rows)
SET STATISTICS IO ON;
SELECT ContribuyenteID, NIT, RazonSocial
FROM dbo.Contribuyente
WHERE ContribuyenteID BETWEEN 1 AND 10000;
SET STATISTICS IO OFF;
GO

-- 5.3.3 -- 15% of rows (30,000 rows)
SET STATISTICS IO ON;
SELECT ContribuyenteID, NIT, RazonSocial
FROM dbo.Contribuyente
WHERE ContribuyenteID BETWEEN 1 AND 30000;
SET STATISTICS IO OFF;
GO

-- 5.3.4 -- 30% of rows (60,000 rows)
SET STATISTICS IO ON;
SELECT ContribuyenteID, NIT, RazonSocial
FROM dbo.Contribuyente
WHERE ContribuyenteID BETWEEN 1 AND 60000;
SET STATISTICS IO OFF;
GO

-- OBSERVACION 5.3
-- Range         Rows      Operator   Reads
-- 1-1,000       1000	   clustered Index Seek        10
-- 1-10,000      ___       ___        ___
-- 1-30,000      ___       ___        ___
-- 1-60,000      ___       ___        ___
-- Tipping point observed at approximately ___% of rows


-- ============================================================
-- 5.4 -- SEEK vs SCAN ON DECLARACION (1.55M ROWS -- HEAP)
-- ============================================================

-- 5.4.1 NC Seek + RID Lookup -- small result set
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

SELECT DeclaracionID, ContribuyenteID, PeriodoFiscal, MontoDeclarado
FROM dbo.Declaracion
WHERE ContribuyenteID = 500;

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-- reads_5.4.1 = 12


-- 5.4.2 Table Scan -- all rows (forced with INDEX = 0)
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

SELECT DeclaracionID, ContribuyenteID, PeriodoFiscal, MontoDeclarado
FROM dbo.Declaracion WITH (INDEX = 0);

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-- reads_5.4.2 = 13852
-- Ratio = reads_5.4.2 / reads_5.4.1 = 1154.33x


-- ============================================================
-- 5.5 -- STATISTICS HEALTH CHECK
-- Stale statistics cause wrong Seek vs Scan decisions.
-- ============================================================

SELECT
    t.name                              AS table_name,
    s.name                              AS statistics_name,
    sp.last_updated,
    sp.rows,
    sp.rows_sampled,
    CAST(sp.rows_sampled * 100.0
         / NULLIF(sp.rows, 0) AS DECIMAL(5,2)) AS sample_pct,
    sp.modification_counter
FROM sys.tables t
JOIN sys.stats s
    ON t.object_id = s.object_id
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE t.name IN ('Contribuyente', 'Declaracion')
ORDER BY t.name, sp.last_updated DESC;
GO

-- OBSERVACION 5.5
-- Si modification_counter supera el 20% del total de filas
-- las estadisticas estan desactualizadas.
-- Ejecutar: UPDATE STATISTICS dbo.Contribuyente WITH FULLSCAN;
