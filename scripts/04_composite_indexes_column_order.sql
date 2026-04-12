-- ============================================================
-- C1300S2 | sql-server-index-audit
-- File   : 04_composite_indexes_column_order.sql
-- Topic  : Composite Indexes and Column Order
-- System : STN_Lab -- Sistema Tributario Nacional (Lab)
-- Author : C13 Carlos Roberto Blanco
-- ============================================================
-- PURPOSE
-- Demonstrate how column order in a composite index determines
-- whether the optimizer can perform a Seek or is forced into
-- a Scan. The B-tree is sorted left to right. The first key
-- column defines the primary sort. A query that filters only
-- on the second column cannot navigate the B-tree efficiently.
-- ============================================================

USE STN_Lab;
GO

-- ============================================================
-- 4.0 -- ENVIRONMENT CHECK
-- ============================================================

SELECT
    i.index_id,
    i.name,
    i.type_desc,
    STRING_AGG(c.name, ', ')
        WITHIN GROUP (ORDER BY ic.key_ordinal) AS key_columns
FROM sys.indexes i
JOIN sys.index_columns ic
    ON i.object_id = ic.object_id
   AND i.index_id  = ic.index_id
JOIN sys.columns c
    ON ic.object_id = c.object_id
   AND ic.column_id = c.column_id
WHERE i.object_id = OBJECT_ID('dbo.Declaracion')
  AND ic.is_included_column = 0
GROUP BY i.index_id, i.name, i.type_desc
ORDER BY i.index_id;
GO


-- ============================================================
-- 4.1 -- COMPOSITE INDEX: HIGH SELECTIVITY FIRST
-- Orden: ContribuyenteID (alta selectividad), PeriodoFiscal
-- Query filtra por ambas columnas.
-- El optimizador navega a ContribuyenteID primero, luego
-- reduce por PeriodoFiscal dentro de esa particion.
-- Expected: Index Seek en ambos predicados
-- ============================================================

CREATE NONCLUSTERED INDEX IX_Declaracion_Contribuyente_Periodo
    ON dbo.Declaracion (ContribuyenteID, PeriodoFiscal)
    INCLUDE (MontoDeclarado, Estado);
GO

SET STATISTICS IO ON;
SET STATISTICS TIME ON;

SELECT
    DeclaracionID,
    ContribuyenteID,
    PeriodoFiscal,
    MontoDeclarado,
    Estado
FROM dbo.Declaracion
WHERE ContribuyenteID = 500
  AND PeriodoFiscal = '2023';    -- replace with existing period

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-- OBSERVACION 4.1
-- reads_4.1 = 5
-- Operator  = Index Seek (ambos predicados usados)


-- ============================================================
-- 4.2 -- MISMO INDICE, FILTRO SOLO EN SEGUNDA COLUMNA
-- El indice es (ContribuyenteID, PeriodoFiscal).
-- Filtrar solo por PeriodoFiscal fuerza un Index Scan completo.
-- El B-tree no puede navegar a PeriodoFiscal sin saber
-- primero el valor de ContribuyenteID.
-- Expected: Index Scan (no Seek)
-- ============================================================

SET STATISTICS IO ON;

SELECT
    DeclaracionID,
    ContribuyenteID,
    PeriodoFiscal,
    MontoDeclarado,
    Estado
FROM dbo.Declaracion
WHERE PeriodoFiscal = '2023';    -- primera columna ausente del filtro

SET STATISTICS IO OFF;
GO

-- OBSERVACION 4.2
-- reads_4.2 = 13852
-- Operator  = Index Scan (segunda columna sola no puede hacer Seek)
-- Esta es la regla de columna lider en la practica.


-- ============================================================
-- 4.3 -- ORDEN INVERTIDO: PeriodoFiscal PRIMERO
-- Construir el indice con PeriodoFiscal como clave lider.
-- Query filtra solo por PeriodoFiscal -- Seek ahora es posible.
-- ============================================================

CREATE NONCLUSTERED INDEX IX_Declaracion_Periodo_Contribuyente
    ON dbo.Declaracion (PeriodoFiscal, ContribuyenteID)
    INCLUDE (MontoDeclarado, Estado);
GO

SET STATISTICS IO ON;

SELECT
    DeclaracionID,
    ContribuyenteID,
    PeriodoFiscal,
    MontoDeclarado,
    Estado
FROM dbo.Declaracion
WHERE PeriodoFiscal = '2023';

SET STATISTICS IO OFF;
GO

-- OBSERVACION 4.3
-- reads_4.3 = 4089
-- Operator  = Index Seek (PeriodoFiscal ahora es la clave lider)
-- Diferencia reads_4.2 vs reads_4.3: mismo filtro, orden diferente


-- ============================================================
-- 4.4 -- IGUALDAD vs RANGO: EL ORDEN IMPORTA MAS AQUI
-- Regla: predicados de igualdad antes que predicados de rango.
-- Un predicado de rango (BETWEEN, >, <) detiene el B-tree
-- de usar columnas clave subsiguientes para el Seek.
-- ============================================================

-- 4.4.1 Orden correcto: igualdad primero, rango segundo
CREATE NONCLUSTERED INDEX IX_Declaracion_Estado_Fecha
    ON dbo.Declaracion (Estado, FechaPresentacion)
    INCLUDE (ContribuyenteID, MontoDeclarado);
GO

SET STATISTICS IO ON;

SELECT
    DeclaracionID,
    ContribuyenteID,
    FechaPresentacion,
    MontoDeclarado,
    Estado
FROM dbo.Declaracion
WHERE Estado = 'P'
  AND FechaPresentacion >= '2023-01-01';

SET STATISTICS IO OFF;
GO

-- reads_4.4.1 = 13852


-- 4.4.2 Orden incorrecto: rango primero, igualdad segundo
CREATE NONCLUSTERED INDEX IX_Declaracion_Fecha_Estado
    ON dbo.Declaracion (FechaPresentacion, Estado)
    INCLUDE (ContribuyenteID, MontoDeclarado);
GO

SET STATISTICS IO ON;

SELECT
    DeclaracionID,
    ContribuyenteID,
    FechaPresentacion,
    MontoDeclarado,
    Estado
FROM dbo.Declaracion
WHERE Estado = 'P'
  AND FechaPresentacion >= '2023-01-01';

SET STATISTICS IO OFF;
GO

-- reads_4.4.2 = 55552
-- OBSERVACION: cual indice eligio el optimizador?
IX_Declaracion_Estado_Fecha


-- ============================================================
-- 4.5 -- COMPARACION DE TAMANO ENTRE VERSIONES DEL INDICE
-- ============================================================

SELECT
    i.name,
    s.used_page_count * 8   AS size_kb,
    s.row_count
FROM sys.dm_db_partition_stats s
JOIN sys.indexes i
    ON s.object_id = i.object_id
   AND s.index_id  = i.index_id
WHERE s.object_id = OBJECT_ID('dbo.Declaracion')
  AND i.name IN (
    'IX_Declaracion_Contribuyente_Periodo',
    'IX_Declaracion_Periodo_Contribuyente',
    'IX_Declaracion_Estado_Fecha',
    'IX_Declaracion_Fecha_Estado'
)
ORDER BY i.name;
GO


-- ============================================================
-- 4.6 -- CLEANUP
-- ============================================================

/*
DROP INDEX IF EXISTS IX_Declaracion_Contribuyente_Periodo ON dbo.Declaracion;
DROP INDEX IF EXISTS IX_Declaracion_Periodo_Contribuyente ON dbo.Declaracion;
DROP INDEX IF EXISTS IX_Declaracion_Estado_Fecha          ON dbo.Declaracion;
DROP INDEX IF EXISTS IX_Declaracion_Fecha_Estado          ON dbo.Declaracion;
*/
