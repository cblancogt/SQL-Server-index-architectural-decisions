-- ============================================================
-- C1300S2 | sql-server-index-audit
-- File   : 02_covered_indexes.sql
-- Topic  : Covered Indexes with INCLUDE Columns
-- System : STN_Lab -- Sistema Tributario Nacional (Lab)
-- Author : C13 | Carlos Roberto
-- ============================================================
-- PURPOSE
-- Demonstrate how INCLUDE columns eliminate Key Lookup and
-- RID Lookup by making the NC index self-sufficient for
-- the query. Measures the read difference between a bare
-- NC index and a covering NC index on the same query.
-- ============================================================

USE STN_Lab;
GO

-- ============================================================
-- 2.0 -- ENVIRONMENT CHECK
-- ============================================================

SELECT
    i.index_id,
    i.name                                          AS index_name,
    i.type_desc                                     AS index_type,
    i.is_primary_key,
    STRING_AGG(
        CASE WHEN ic.is_included_column = 0 THEN c.name END, ', ')
        WITHIN GROUP (ORDER BY ic.key_ordinal)      AS key_columns,
    STRING_AGG(
        CASE WHEN ic.is_included_column = 1 THEN c.name END, ', ')
        WITHIN GROUP (ORDER BY ic.key_ordinal)      AS included_columns
FROM sys.indexes i
JOIN sys.index_columns ic
    ON i.object_id = ic.object_id
   AND i.index_id  = ic.index_id
JOIN sys.columns c
    ON ic.object_id = c.object_id
   AND ic.column_id = c.column_id
WHERE i.object_id = OBJECT_ID('dbo.Contribuyente')
GROUP BY i.index_id, i.name, i.type_desc, i.is_primary_key
ORDER BY i.index_id;
GO

-- ============================================================
-- 2.1 -- BASELINE: BARE NC INDEX (no INCLUDE)
-- IX_Contribuyente_NIT exists but covers only NIT.
-- Query requests RazonSocial and Estado -- both outside
-- the index. Each matched row triggers a Key Lookup.
-- Expected: Index Seek + Key Lookup (Nested Loops)
-- ============================================================

SET STATISTICS IO ON;
SET STATISTICS TIME ON;

SELECT
    ContribuyenteID,
    NIT,
    RazonSocial,
    Estado
FROM dbo.Contribuyente
WHERE NIT = '2010219';    -- replace with existing NIT

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-- OBSERVACION 2.1
-- reads_2.1        = _6__
-- Operator         = Index Seek + Key Lookup
-- Key Lookup cost% = _50%__


-- ============================================================
-- 2.2 -- CREATE COVERING INDEX WITH INCLUDE
-- RazonSocial and Estado live only at the leaf level.
-- They are not part of the sort key -- just passengers that
-- eliminate the return trip to the clustered index.
-- ============================================================

CREATE NONCLUSTERED INDEX IX_Contribuyente_NIT_Cubierto
    ON dbo.Contribuyente (NIT)
    INCLUDE (RazonSocial, Estado, ContribuyenteID);
GO


-- ============================================================
-- 2.3 -- SAME QUERY WITH COVERING INDEX
-- Expected: Index Seek only -- no Key Lookup
-- ============================================================

SET STATISTICS IO ON;
SET STATISTICS TIME ON;

SELECT
    ContribuyenteID,
    NIT,
    RazonSocial,
    Estado
FROM dbo.Contribuyente
WHERE NIT = '2010219';

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-- OBSERVACION 2.3
-- reads_2.3  = _3__
-- Operator   = Index Seek only
-- Diferencia vs 2.1 = _3__


-- ============================================================
-- 2.4 -- COVERAGE BREAKS WHEN COLUMN IS OUTSIDE INCLUDE
-- Adding TipoPersona to the SELECT forces Key Lookup back.
-- Coverage must match the actual query pattern exactly.
-- ============================================================

SET STATISTICS IO ON;

SELECT
    ContribuyenteID,
    NIT,
    RazonSocial,
    Estado,
    TipoPersona    -- not in INCLUDE
FROM dbo.Contribuyente
WHERE NIT = '2010219';

SET STATISTICS IO OFF;
GO

-- OBSERVACION 2.4
-- Operator   = Index Seek + Key Lookup (returned)
-- Conclusion = coverage is query-specific, not table-wide


-- ============================================================
-- 2.5 -- COVERING INDEX ON DECLARACION (HEAP -- RID LOOKUP)
-- Bare NC index on ContribuyenteID produces RID Lookup
-- at 89% cost as observed in script 01.
-- Adding INCLUDE columns eliminates the RID Lookup
-- even on a heap table.
-- ============================================================

-- 2.5.1 Baseline: bare NC -- RID Lookup confirmed
SET STATISTICS IO ON;

SELECT
    DeclaracionID,
    ContribuyenteID,
    PeriodoFiscal,
    MontoDeclarado,
    Estado
FROM dbo.Declaracion
WHERE ContribuyenteID = 500;

SET STATISTICS IO OFF;
GO

-- reads_2.5.1 = _12__
-- Operator    = Index Seek + RID Lookup (Heap)


-- 2.5.2 Create covering index on Declaracion
CREATE NONCLUSTERED INDEX IX_Declaracion_Contribuyente_Cubierto
    ON dbo.Declaracion (ContribuyenteID)
    INCLUDE (PeriodoFiscal, MontoDeclarado, Estado, DeclaracionID);
GO


-- 2.5.3 Same query -- RID Lookup should disappear
SET STATISTICS IO ON;

SELECT
    DeclaracionID,
    ContribuyenteID,
    PeriodoFiscal,
    MontoDeclarado,
    Estado
FROM dbo.Declaracion
WHERE ContribuyenteID = 500;

SET STATISTICS IO OFF;
GO

-- reads_2.5.3 = _3__
-- Operator    = Index Seek only -- no RID Lookup
-- Diferencia vs 2.5.1 = _9__


-- ============================================================
-- 2.6 -- INCLUDE VS KEY COLUMN
-- INCLUDE columns live at the leaf level only.
-- They cannot be used as filter predicates in WHERE.
-- If a column needs to filter AND be covered, it must
-- be a key column in the index, not just INCLUDE.
-- ============================================================

SET STATISTICS IO ON;

SELECT
    ContribuyenteID,
    NIT,
    RazonSocial,
    Estado
FROM dbo.Contribuyente WITH (INDEX = IX_Contribuyente_NIT_Cubierto)
WHERE Estado = 'B';    -- Estado is INCLUDE, not a key column

SET STATISTICS IO OFF;
GO

-- OBSERVACION 2.6
-- Expected = Index Scan (cannot Seek on an INCLUDE column)


-- ============================================================
-- 2.7 -- SIZE COMPARISON: BARE vs COVERING INDEX
-- INCLUDE columns add storage at the leaf level.
-- This query shows the size cost of coverage.
-- ============================================================

SELECT
    i.name                      AS index_name,
    s.used_page_count * 8       AS size_kb,
    s.row_count
FROM sys.dm_db_partition_stats s
JOIN sys.indexes i
    ON s.object_id = i.object_id
   AND s.index_id  = i.index_id
WHERE s.object_id IN (
    OBJECT_ID('dbo.Contribuyente'),
    OBJECT_ID('dbo.Declaracion')
)
  AND i.name IN (
    'IX_Contribuyente_NIT',
    'IX_Contribuyente_NIT_Cubierto',
    'IX_Declaracion_ContribuyenteID',
    'IX_Declaracion_Contribuyente_Cubierto'
)
ORDER BY s.object_id, i.name;
GO

-- OBSERVACION 2.7
-- Anotar size_kb de cada indice y calcular la diferencia.
-- Esa diferencia es el costo de storage de la cobertura.


-- ============================================================
-- 2.8 -- CLEANUP
-- ============================================================

/*
DROP INDEX IF EXISTS IX_Contribuyente_NIT_Cubierto         ON dbo.Contribuyente;
DROP INDEX IF EXISTS IX_Declaracion_Contribuyente_Cubierto ON dbo.Declaracion;
*/
