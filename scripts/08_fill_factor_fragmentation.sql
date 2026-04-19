-- ============================================================
-- C1300S2 | sql-server-index-audit
-- File   : 08_fill_factor_fragmentation.sql
-- Topic  : Fill Factor and Fragmentation
-- System : STN_Lab -- Sistema Tributario Nacional (Lab)
-- Author : C13
-- ============================================================
-- PURPOSE
-- Analyze index fragmentation using sys.dm_db_index_physical_stats.
-- Determine when to use REBUILD vs REORGANIZE based on
-- fragmentation thresholds. Document the fill factor decision
-- for STN based on insert and update patterns.
-- ============================================================

USE STN_Lab;
GO

-- ============================================================
-- 8.0 -- ENVIRONMENT CHECK
-- Fill factor actual de cada indice en STN.
-- ============================================================

SELECT
    t.name                          AS table_name,
    i.name                          AS index_name,
    i.type_desc,
    i.fill_factor,
    s.used_page_count * 8           AS size_kb,
    s.row_count
FROM sys.indexes i
JOIN sys.tables t
    ON i.object_id = t.object_id
JOIN sys.dm_db_partition_stats s
    ON i.object_id = s.object_id
   AND i.index_id  = s.index_id
WHERE t.name IN ('Contribuyente', 'Declaracion', 'Pago', 'AuditoriaFiscal')
  AND i.index_id > 0
ORDER BY t.name, i.index_id;
GO

-- OBSERVACION 8.0
-- fill_factor = 0 significa 100% (paginas llenas al crear).
-- Anotar fill_factor actual de cada indice.


-- ============================================================
-- 8.1 -- ANALISIS DE FRAGMENTACION
-- avg_fragmentation_in_percent: porcentaje de paginas
-- fuera de orden logico vs orden fisico.
-- page_count: numero de paginas del indice.
-- ============================================================

SELECT
    t.name                                  AS table_name,
    i.name                                  AS index_name,
    i.type_desc,
    s.avg_fragmentation_in_percent,
    s.page_count,
    s.avg_page_space_used_in_percent,
    CASE
        WHEN s.avg_fragmentation_in_percent < 5  THEN 'Sin accion'
        WHEN s.avg_fragmentation_in_percent < 30 THEN 'REORGANIZE'
        ELSE 'REBUILD'
    END AS accion_recomendada
FROM sys.dm_db_index_physical_stats(
    DB_ID(), NULL, NULL, NULL, 'SAMPLED') s
JOIN sys.indexes i
    ON s.object_id = i.object_id
   AND s.index_id  = i.index_id
JOIN sys.tables t
    ON i.object_id = t.object_id
WHERE t.name IN ('Contribuyente', 'Declaracion', 'Pago', 'AuditoriaFiscal')
  AND s.page_count > 8
ORDER BY s.avg_fragmentation_in_percent DESC;
GO

-- OBSERVACION 8.1
-- Anotar indices con accion_recomendada distinta a "Sin accion".
-- page_count menor a 8 se ignora -- el overhead de mantenimiento
-- supera el beneficio en indices muy pequenos.


-- ============================================================
-- 8.2 -- REORGANIZE vs REBUILD -- DECISION
-- REORGANIZE : operacion online, desfragmenta nivel hoja.
--              Usar cuando fragmentacion entre 5% y 30%.
--              No actualiza estadisticas.
-- REBUILD     : recrea el indice completo. Puede ser offline.
--              Usar cuando fragmentacion supera 30%.
--              Actualiza estadisticas automaticamente.
-- ============================================================

-- 8.2.1 Reorganize -- indice con fragmentacion moderada
-- Reemplazar con el indice que requiera REORGANIZE segun 8.1
ALTER INDEX IX_Contribuyente_NIT ON dbo.Contribuyente REORGANIZE;
GO

-- Verificar fragmentacion despues del REORGANIZE
SELECT
    i.name,
    s.avg_fragmentation_in_percent,
    s.page_count
FROM sys.dm_db_index_physical_stats(
    DB_ID(), OBJECT_ID('dbo.Contribuyente'), NULL, NULL, 'SAMPLED') s
JOIN sys.indexes i
    ON s.object_id = i.object_id
   AND s.index_id  = i.index_id
WHERE i.name = 'IX_Contribuyente_NIT';
GO

-- reads_8.2.1_antes = ___
-- reads_8.2.1_despues = ___


-- 8.2.2 Rebuild -- indice con fragmentacion alta
-- Reemplazar con el indice que requiera REBUILD segun 8.1
ALTER INDEX IX_Declaracion_ContribuyenteID ON dbo.Declaracion REBUILD;
GO

-- Verificar fragmentacion despues del REBUILD
SELECT
    i.name,
    s.avg_fragmentation_in_percent,
    s.page_count
FROM sys.dm_db_index_physical_stats(
    DB_ID(), OBJECT_ID('dbo.Declaracion'), NULL, NULL, 'SAMPLED') s
JOIN sys.indexes i
    ON s.object_id = i.object_id
   AND s.index_id  = i.index_id
WHERE i.name = 'IX_Declaracion_ContribuyenteID';
GO

-- reads_8.2.2_antes = ___
-- reads_8.2.2_despues = ___


-- ============================================================
-- 8.3 -- FILL FACTOR: IMPACTO EN FRAGMENTACION
-- Fill factor define que porcentaje de cada pagina se llena
-- al crear o reconstruir el indice.
-- Pagina llena (100%): maxima densidad, fragmenta rapido
--                      con inserciones intermedias.
-- Pagina parcial (80%): deja espacio para crecer,
--                       reduce page splits en tablas activas.
-- ============================================================

-- 8.3.1 Rebuild con fill factor 80% para tabla con muchos inserts
ALTER INDEX IX_Declaracion_ContribuyenteID
    ON dbo.Declaracion
    REBUILD WITH (FILLFACTOR = 80);
GO

SELECT
    i.name,
    i.fill_factor,
    s.avg_fragmentation_in_percent,
    s.avg_page_space_used_in_percent
FROM sys.dm_db_index_physical_stats(
    DB_ID(), OBJECT_ID('dbo.Declaracion'), NULL, NULL, 'SAMPLED') s
JOIN sys.indexes i
    ON s.object_id = i.object_id
   AND s.index_id  = i.index_id
WHERE i.name = 'IX_Declaracion_ContribuyenteID';
GO

-- OBSERVACION 8.3
-- avg_page_space_used_in_percent debe mostrar ~80%.
-- Con inserts continuos el indice tardara mas en fragmentarse
-- que con fill_factor = 100.


-- ============================================================
-- 8.4 -- SCRIPT DE MANTENIMIENTO AUTOMATIZADO
-- Genera los comandos de mantenimiento para todos los indices
-- segun el umbral de fragmentacion detectado en 8.1.
-- ============================================================

SELECT
    'ALTER INDEX [' + i.name + '] ON [dbo].[' + t.name + '] ' +
    CASE
        WHEN s.avg_fragmentation_in_percent < 5  THEN '-- Sin accion requerida'
        WHEN s.avg_fragmentation_in_percent < 30 THEN 'REORGANIZE;'
        ELSE 'REBUILD WITH (FILLFACTOR = 80, ONLINE = OFF);'
    END AS maintenance_command,
    CAST(s.avg_fragmentation_in_percent AS DECIMAL(5,2)) AS fragmentation_pct,
    s.page_count
FROM sys.dm_db_index_physical_stats(
    DB_ID(), NULL, NULL, NULL, 'SAMPLED') s
JOIN sys.indexes i
    ON s.object_id = i.object_id
   AND s.index_id  = i.index_id
JOIN sys.tables t
    ON i.object_id = t.object_id
WHERE t.name IN ('Contribuyente', 'Declaracion', 'Pago', 'AuditoriaFiscal')
  AND s.page_count > 8
  AND i.index_id > 0
ORDER BY s.avg_fragmentation_in_percent DESC;
GO

-- OBSERVACION 8.4
-- Copiar los comandos generados y ejecutarlos en orden.
-- Guardar el script como parte del plan de mantenimiento STN.
