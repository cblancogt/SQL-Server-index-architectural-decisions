-- ============================================================
-- C1300S2 | sql-server-index-audit
-- File   : 07_duplicate_redundant_indexes.sql
-- Topic  : Duplicate and Redundant Indexes
-- System : STN_Lab -- Sistema Tributario Nacional (Lab)
-- Author : C13
-- ============================================================
-- PURPOSE
-- Detect indexes that duplicate or overlap existing ones.
-- Every duplicate index adds overhead to INSERT, UPDATE and
-- DELETE without adding read benefit. Identify and document
-- which ones are safe to remove.
-- ============================================================

USE STN_Lab;
GO

-- ============================================================
-- 7.0 -- ENVIRONMENT CHECK
-- Estado actual de todos los indices en las tablas STN.
-- ============================================================

SELECT
    t.name                                          AS table_name,
    i.index_id,
    i.name                                          AS index_name,
    i.type_desc,
    i.is_unique,
    i.is_primary_key,
    STRING_AGG(
        CASE WHEN ic.is_included_column = 0 THEN c.name END, ', ')
        WITHIN GROUP (ORDER BY ic.key_ordinal)      AS key_columns,
    STRING_AGG(
        CASE WHEN ic.is_included_column = 1 THEN c.name END, ', ')
        WITHIN GROUP (ORDER BY ic.key_ordinal)      AS included_columns
FROM sys.indexes i
JOIN sys.tables t
    ON i.object_id = t.object_id
JOIN sys.index_columns ic
    ON i.object_id = ic.object_id
   AND i.index_id  = ic.index_id
JOIN sys.columns c
    ON ic.object_id = c.object_id
   AND ic.column_id = c.column_id
WHERE t.name IN ('Contribuyente', 'Declaracion', 'Pago', 'AuditoriaFiscal')
GROUP BY t.name, i.index_id, i.name, i.type_desc, i.is_unique, i.is_primary_key
ORDER BY t.name, i.index_id;
GO


-- ============================================================
-- 7.1 -- DETECTAR INDICES DUPLICADOS EXACTOS
-- Misma tabla, mismas columnas clave en el mismo orden.
-- Uno de los dos es completamente prescindible.
-- ============================================================

SELECT
    t.name                                          AS table_name,
    i1.name                                         AS index_1,
    i2.name                                         AS index_2,
    key_cols.key_columns
FROM sys.indexes i1
JOIN sys.indexes i2
    ON i1.object_id = i2.object_id
   AND i1.index_id  < i2.index_id
   AND i1.type_desc = i2.type_desc
JOIN sys.tables t
    ON i1.object_id = t.object_id
CROSS APPLY (
    SELECT STRING_AGG(c.name, ', ')
        WITHIN GROUP (ORDER BY ic.key_ordinal) AS key_columns
    FROM sys.index_columns ic
    JOIN sys.columns c
        ON ic.object_id = c.object_id
       AND ic.column_id = c.column_id
    WHERE ic.object_id = i1.object_id
      AND ic.index_id  = i1.index_id
      AND ic.is_included_column = 0
) key_cols
WHERE key_cols.key_columns = (
    SELECT STRING_AGG(c.name, ', ')
        WITHIN GROUP (ORDER BY ic.key_ordinal)
    FROM sys.index_columns ic
    JOIN sys.columns c
        ON ic.object_id = c.object_id
       AND ic.column_id = c.column_id
    WHERE ic.object_id = i2.object_id
      AND ic.index_id  = i2.index_id
      AND ic.is_included_column = 0
)
  AND t.name IN ('Contribuyente', 'Declaracion', 'Pago', 'AuditoriaFiscal')
ORDER BY t.name;
GO

-- OBSERVACION 7.1
-- Anotar pares de indices duplicados encontrados.
-- Si no hay resultados: no existen duplicados exactos.


-- ============================================================
-- 7.2 -- DETECTAR INDICES REDUNDANTES
-- Un indice es redundante si otro indice existente tiene
-- las mismas columnas lider mas columnas adicionales.
-- El indice mas corto no agrega valor de Seek.
-- ============================================================

SELECT
    t.name                                          AS table_name,
    i_short.name                                    AS index_redundante,
    i_long.name                                     AS index_que_lo_cubre,
    short_cols.key_columns                          AS columnas_redundante,
    long_cols.key_columns                           AS columnas_cubridor
FROM sys.indexes i_short
JOIN sys.indexes i_long
    ON i_short.object_id = i_long.object_id
   AND i_short.index_id  <> i_long.index_id
   AND i_short.type_desc  = i_long.type_desc
JOIN sys.tables t
    ON i_short.object_id = t.object_id
CROSS APPLY (
    SELECT STRING_AGG(c.name, ', ')
        WITHIN GROUP (ORDER BY ic.key_ordinal) AS key_columns
    FROM sys.index_columns ic
    JOIN sys.columns c
        ON ic.object_id = c.object_id
       AND ic.column_id = c.column_id
    WHERE ic.object_id = i_short.object_id
      AND ic.index_id  = i_short.index_id
      AND ic.is_included_column = 0
) short_cols
CROSS APPLY (
    SELECT STRING_AGG(c.name, ', ')
        WITHIN GROUP (ORDER BY ic.key_ordinal) AS key_columns
    FROM sys.index_columns ic
    JOIN sys.columns c
        ON ic.object_id = c.object_id
       AND ic.column_id = c.column_id
    WHERE ic.object_id = i_long.object_id
      AND ic.index_id  = i_long.index_id
      AND ic.is_included_column = 0
) long_cols
WHERE long_cols.key_columns LIKE short_cols.key_columns + '%'
  AND i_short.is_primary_key = 0
  AND i_long.is_primary_key  = 0
  AND t.name IN ('Contribuyente', 'Declaracion', 'Pago', 'AuditoriaFiscal')
ORDER BY t.name;
GO

-- OBSERVACION 7.2
-- Anotar indices redundantes encontrados.
-- El index_redundante puede eliminarse si index_que_lo_cubre
-- tiene las mismas o mas columnas lider.


-- ============================================================
-- 7.3 -- INDICES SIN USO (DMV)
-- Indices que existen pero que el optimizador no ha usado
-- desde el ultimo reinicio del servicio.
-- ============================================================

SELECT
    t.name                          AS table_name,
    i.name                          AS index_name,
    i.type_desc,
    ISNULL(us.user_seeks, 0)        AS user_seeks,
    ISNULL(us.user_scans, 0)        AS user_scans,
    ISNULL(us.user_lookups, 0)      AS user_lookups,
    ISNULL(us.user_updates, 0)      AS user_updates,
    s.used_page_count * 8           AS size_kb
FROM sys.indexes i
JOIN sys.tables t
    ON i.object_id = t.object_id
JOIN sys.dm_db_partition_stats s
    ON i.object_id = s.object_id
   AND i.index_id  = s.index_id
LEFT JOIN sys.dm_db_index_usage_stats us
    ON i.object_id = us.object_id
   AND i.index_id  = us.index_id
   AND us.database_id = DB_ID()
WHERE t.name IN ('Contribuyente', 'Declaracion', 'Pago', 'AuditoriaFiscal')
  AND i.index_id > 0
  AND i.is_primary_key = 0
ORDER BY ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) ASC;
GO

-- OBSERVACION 7.3
-- Indices con user_seeks = 0 y user_scans = 0 no han sido
-- usados para lectura. Si user_updates es alto representan
-- overhead puro en escritura sin beneficio en lectura.
-- Candidatos a eliminacion previa validacion en produccion.


-- ============================================================
-- 7.4 -- COSTO DE ESCRITURA POR INDICE
-- Cada indice adicional incrementa el costo de INSERT,
-- UPDATE y DELETE. Esta query muestra el overhead real.
-- ============================================================

SELECT
    t.name                          AS table_name,
    i.name                          AS index_name,
    ISNULL(us.user_updates, 0)      AS write_operations,
    ISNULL(us.user_seeks, 0)
    + ISNULL(us.user_scans, 0)      AS read_operations,
    CASE
        WHEN ISNULL(us.user_seeks, 0)
           + ISNULL(us.user_scans, 0) = 0 THEN 'Solo escritura -- candidato a eliminar'
        WHEN ISNULL(us.user_updates, 0)
           > (ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0)) * 10
            THEN 'Escritura supera lectura 10x -- evaluar'
        ELSE 'Balance aceptable'
    END AS evaluacion
FROM sys.indexes i
JOIN sys.tables t
    ON i.object_id = t.object_id
LEFT JOIN sys.dm_db_index_usage_stats us
    ON i.object_id = us.object_id
   AND i.index_id  = us.index_id
   AND us.database_id = DB_ID()
WHERE t.name IN ('Contribuyente', 'Declaracion', 'Pago', 'AuditoriaFiscal')
  AND i.index_id > 0
  AND i.is_primary_key = 0
ORDER BY t.name, ISNULL(us.user_updates, 0) DESC;
GO

-- OBSERVACION 7.4
-- Anotar indices con evaluacion distinta a "Balance aceptable".
