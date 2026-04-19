-- ============================================================
-- C1300S2 | sql-server-index-audit
-- File   : 06_missing_index_dmvs.sql
-- Topic  : Missing Index DMVs
-- System : STN_Lab -- Sistema Tributario Nacional (Lab)
-- Author : C13
-- ============================================================
-- PURPOSE
-- Query sys.dm_db_missing_index_* DMVs to identify indexes
-- SQL Server recommends based on actual query execution.
-- Apply a priority threshold to avoid implementing every
-- suggestion blindly.
-- ============================================================

USE STN_Lab;
GO

-- ============================================================
-- 6.0 -- GENERATE MISSING INDEX SIGNAL
-- Run queries that trigger missing index recommendations.
-- DMVs only populate after queries execute without a
-- suitable index -- cold DMVs produce no results.
-- ============================================================

SET STATISTICS IO ON;

SELECT ContribuyenteID, NIT, RazonSocial, DepartamentoID, TipoPersona
FROM dbo.Contribuyente
WHERE DepartamentoID = 1
  AND TipoPersona = 'J';

SELECT ContribuyenteID, NIT, RazonSocial
FROM dbo.Contribuyente
WHERE TipoPersona = 'N'
  AND Estado = 'A';

SELECT DeclaracionID, ContribuyenteID, PeriodoFiscal, MontoImpuesto
FROM dbo.Declaracion
WHERE FechaPresentacion >= '2023-01-01'
  AND TipoImpuestoID = 1;

SELECT DeclaracionID, ContribuyenteID, MontoDeclarado, Estado
FROM dbo.Declaracion
WHERE Estado = 'P'
  AND PeriodoFiscal = '2023';

SET STATISTICS IO OFF;
GO


-- ============================================================
-- 6.1 -- RAW MISSING INDEX RECOMMENDATIONS
-- Sin filtro -- incluye sugerencias de bajo valor.
-- ============================================================

SELECT
    OBJECT_NAME(mid.object_id)          AS table_name,
    mid.equality_columns,
    mid.inequality_columns,
    mid.included_columns,
    migs.user_seeks,
    migs.user_scans,
    migs.avg_total_user_cost,
    migs.avg_user_impact
FROM sys.dm_db_missing_index_details mid
JOIN sys.dm_db_missing_index_groups mig
    ON mid.index_handle = mig.index_handle
JOIN sys.dm_db_missing_index_group_stats migs
    ON mig.index_group_handle = migs.group_handle
WHERE mid.database_id = DB_ID()
ORDER BY migs.avg_total_user_cost * migs.avg_user_impact DESC;
GO

-- OBSERVACION 6.1
-- Anotar cuantas sugerencias aparecen y para que tablas.


-- ============================================================
-- 6.2 -- PRIORITIZED MISSING INDEX REPORT
-- Impact score = user_seeks x avg_cost x avg_impact / 100
-- Solo implementar indexes con score mayor a 1,000.
-- ============================================================

SELECT
    OBJECT_NAME(mid.object_id)                          AS table_name,
    mid.equality_columns,
    mid.inequality_columns,
    mid.included_columns,
    migs.user_seeks,
    CAST(migs.avg_user_impact AS DECIMAL(5,1))          AS impact_pct,
    CAST(
        migs.user_seeks
        * migs.avg_total_user_cost
        * migs.avg_user_impact / 100.0
    AS DECIMAL(18,2))                                   AS priority_score,
    'CREATE NONCLUSTERED INDEX [IX_Missing_' +
        CAST(mig.index_group_handle AS VARCHAR) + '] ON ' +
        mid.statement + ' (' +
        ISNULL(mid.equality_columns, '') +
        CASE
            WHEN mid.equality_columns IS NOT NULL
             AND mid.inequality_columns IS NOT NULL THEN ', '
            ELSE ''
        END +
        ISNULL(mid.inequality_columns, '') + ')' +
        ISNULL(' INCLUDE (' + mid.included_columns + ')', '')
    AS suggested_index
FROM sys.dm_db_missing_index_details mid
JOIN sys.dm_db_missing_index_groups mig
    ON mid.index_handle = mig.index_handle
JOIN sys.dm_db_missing_index_group_stats migs
    ON mig.index_group_handle = migs.group_handle
WHERE mid.database_id = DB_ID()
  AND migs.user_seeks > 0
ORDER BY priority_score DESC;
GO

-- OBSERVACION 6.2
-- Anotar top 3 recomendaciones:
-- 1. Table: ___ | Columns: ___ | Score: ___
-- 2. Table: ___ | Columns: ___ | Score: ___
-- 3. Table: ___ | Columns: ___ | Score: ___


-- ============================================================
-- 6.3 -- IMPLEMENTAR LA RECOMENDACION CON MAYOR SCORE
-- Comparar logical reads antes y despues.
-- ============================================================

-- 6.3.1 Baseline antes de implementar
SET STATISTICS IO ON;

SELECT DeclaracionID, ContribuyenteID, PeriodoFiscal, MontoImpuesto
FROM dbo.Declaracion
WHERE FechaPresentacion >= '2023-01-01'
  AND TipoImpuestoID = 1;

SET STATISTICS IO OFF;
GO

-- reads_6.3.1 = ___

-- 6.3.2 Crear el indice sugerido (ajustar segun resultado de 6.2)
-- Reemplazar con el CREATE INDEX generado en 6.2
/*
CREATE NONCLUSTERED INDEX IX_Declaracion_Fecha_TipoImpuesto
    ON dbo.Declaracion (FechaPresentacion, TipoImpuestoID)
    INCLUDE (DeclaracionID, ContribuyenteID, PeriodoFiscal, MontoImpuesto);
GO
*/

-- 6.3.3 Re-ejecutar el mismo query
SET STATISTICS IO ON;

SELECT DeclaracionID, ContribuyenteID, PeriodoFiscal, MontoImpuesto
FROM dbo.Declaracion
WHERE FechaPresentacion >= '2023-01-01'
  AND TipoImpuestoID = 1;

SET STATISTICS IO OFF;
GO

-- reads_6.3.3 = ___
-- Diferencia vs 6.3.1 = ___


-- ============================================================
-- 6.4 -- LIMITACIONES DE LOS DMVs
-- Los DMVs se resetean con cada reinicio del servicio.
-- No reflejan el historico real de produccion.
-- Una sugerencia con score alto en lab puede ser irrelevante
-- en produccion si el query no se ejecuta frecuentemente.
-- ============================================================

SELECT
    sqlserver_start_time
FROM sys.dm_os_sys_info;
GO

-- OBSERVACION 6.4
-- Anotar desde cuando estan corriendo los DMVs.
-- Si el servicio se reinicio recientemente los datos son parciales.


-- ============================================================
-- 6.5 -- CLEANUP
-- ============================================================

/*
DROP INDEX IF EXISTS IX_Declaracion_Fecha_TipoImpuesto ON dbo.Declaracion;
*/
