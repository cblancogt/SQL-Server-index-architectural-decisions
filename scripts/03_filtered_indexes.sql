-- ============================================================
-- C1300S2 | sql-server-index-audit
-- File   : 03_filtered_indexes.sql
-- Topic  : Filtered Indexes
-- System : STN_Lab -- Sistema Tributario Nacional (Lab)
-- Author : C13 | Carlos Roberto
-- ============================================================
-- PURPOSE
-- Demonstrate filtered indexes -- NC indexes that only include
-- rows matching a WHERE predicate. Useful when a minority
-- value is queried frequently but represents a small fraction
-- of the table. Compares size and seek performance against
-- a full NC index on the same column.
-- ============================================================

USE STN_Lab;
GO

-- ============================================================
-- 3.0 -- ENVIRONMENT CHECK
-- Review Estado distribution before creating any index.
-- A filtered index only makes sense for low-frequency values.
-- ============================================================

SELECT
    Estado,
    COUNT(*)                                        AS total,
    CAST(COUNT(*) * 100.0
         / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))  AS porcentaje
FROM dbo.Contribuyente
GROUP BY Estado
ORDER BY total DESC;
GO

-- OBSERVACION 3.0
-- Anotar la distribucion. Valores con menos del 10% son
-- candidatos a indice filtrado. Valores con mas del 50% no.
-- Confirmado en script 01: Estado = 'A' es 94% -- nunca filtrar aqui.


-- ============================================================
-- 3.1 -- BASELINE: FULL NC INDEX ON Estado
-- Un indice completo cubre todos los valores de Estado
-- sin importar frecuencia. Indice grande, baja selectividad
-- para los valores mayoritarios.
-- ============================================================

CREATE NONCLUSTERED INDEX IX_Contribuyente_Estado_Full
    ON dbo.Contribuyente (Estado)
    INCLUDE (NIT, RazonSocial);
GO

SELECT
    i.name,
    s.used_page_count * 8   AS size_kb,
    s.row_count
FROM sys.dm_db_partition_stats s
JOIN sys.indexes i
    ON s.object_id = i.object_id
   AND s.index_id  = i.index_id
WHERE s.object_id = OBJECT_ID('dbo.Contribuyente')
  AND i.name = 'IX_Contribuyente_Estado_Full';
GO

-- OBSERVACION 3.1
-- size_kb_full = 8632
-- row_count    = 200000 (debe ser 200,000 -- todas las filas)


-- ============================================================
-- 3.2 -- FILTERED INDEX ON MINORITY Estado VALUE
-- Solo indexa las filas que realmente necesitan acceso rapido.
-- Reemplazar 'S' con el valor de menor frecuencia en 3.0.
-- ============================================================

CREATE NONCLUSTERED INDEX IX_Contribuyente_Estado_Filtrado
    ON dbo.Contribuyente (Estado)
    INCLUDE (NIT, RazonSocial)
    WHERE Estado = 'S';    -- replace with lowest-frequency value
GO

SELECT
    i.name,
    s.used_page_count * 8   AS size_kb,
    s.row_count
FROM sys.dm_db_partition_stats s
JOIN sys.indexes i
    ON s.object_id = i.object_id
   AND s.index_id  = i.index_id
WHERE s.object_id = OBJECT_ID('dbo.Contribuyente')
  AND i.name = 'IX_Contribuyente_Estado_Filtrado';
GO

-- OBSERVACION 3.2
-- size_kb_filtrado = 104  (debe ser mucho menor que 3.1)
-- row_count        = 2000  (solo filas donde Estado = 'S')
-- Reduccion        = 98.8% vs indice completo


-- ============================================================
-- 3.3 -- QUERY PERFORMANCE: FULL vs FILTERED INDEX
-- Ambos indices cubren el mismo query para Estado = 'S'.
-- El indice filtrado es mas pequeno -- menos paginas a leer.
-- ============================================================

-- 3.3.1 Forzar indice completo
SET STATISTICS IO ON;

SELECT ContribuyenteID, NIT, RazonSocial, Estado
FROM dbo.Contribuyente WITH (INDEX = IX_Contribuyente_Estado_Full)
WHERE Estado = 'S';

SET STATISTICS IO OFF;
GO

-- reads_3.3.1 = 15


-- 3.3.2 Forzar indice filtrado
SET STATISTICS IO ON;

SELECT ContribuyenteID, NIT, RazonSocial, Estado
FROM dbo.Contribuyente WITH (INDEX = IX_Contribuyente_Estado_Filtrado)
WHERE Estado = 'S';

SET STATISTICS IO OFF;
GO

-- reads_3.3.2 = 13
-- Diferencia vs 3.3.1 = 2


-- ============================================================
-- 3.4 -- FILTERED INDEX LIMITATION
-- Un indice filtrado SOLO funciona cuando el predicado del
-- query coincide exactamente con el filtro del indice.
-- Si el predicado difiere, el optimizador no puede usarlo.
-- ============================================================

-- 3.4.1 Funciona -- predicado coincide con el filtro
SET STATISTICS IO ON;

SELECT ContribuyenteID, NIT, RazonSocial, Estado
FROM dbo.Contribuyente
WHERE Estado = 'S';

SET STATISTICS IO OFF;
GO

-- OBSERVACION 3.4.1
-- Operator = Index Seek sobre indice filtrado


-- 3.4.2 No usa el indice filtrado -- predicado diferente
SET STATISTICS IO ON;

SELECT ContribuyenteID, NIT, RazonSocial, Estado
FROM dbo.Contribuyente
WHERE Estado <> 'A';    -- predicado diferente al filtro

SET STATISTICS IO OFF;
GO

-- OBSERVACION 3.4.2
-- Operator = Scan -- indice filtrado no aplica
-- Conclusion: indice filtrado sirve un predicado exacto, no un rango


-- ============================================================
-- 3.5 -- FILTERED INDEX EN AUDITORIAFISCAL
-- Verificar estructura y distribucion antes de crear.
-- ============================================================

-- Estructura de AuditoriaFiscal
SELECT
    i.index_id,
    i.name,
    i.type_desc
FROM sys.indexes i
WHERE i.object_id = OBJECT_ID('dbo.AuditoriaFiscal')
ORDER BY i.index_id;
GO

-- Distribucion de Estado en AuditoriaFiscal
SELECT
    Estado,
    COUNT(*)                                        AS total,
    CAST(COUNT(*) * 100.0
         / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))  AS porcentaje
FROM dbo.AuditoriaFiscal
GROUP BY Estado
ORDER BY total DESC;
GO

-- OBSERVACION 3.5
-- Anotar distribucion. Crear indice filtrado solo si existe
-- un valor minoritario consultado frecuentemente.


-- ============================================================
-- 3.6 -- OPTIMIZER CHOICE WITHOUT HINTS
-- Verificar cual indice elige el optimizador sin forzar.
-- ============================================================

SET STATISTICS IO ON;

SELECT ContribuyenteID, NIT, RazonSocial, Estado
FROM dbo.Contribuyente
WHERE Estado = 'S';

SET STATISTICS IO OFF;
GO

-- OBSERVACION 3.6
-- Indice elegido por el optimizador = Index Seek


-- ============================================================
-- 3.7 -- CLEANUP
-- ============================================================

/*
DROP INDEX IF EXISTS IX_Contribuyente_Estado_Full     ON dbo.Contribuyente;
DROP INDEX IF EXISTS IX_Contribuyente_Estado_Filtrado ON dbo.Contribuyente;
*/
