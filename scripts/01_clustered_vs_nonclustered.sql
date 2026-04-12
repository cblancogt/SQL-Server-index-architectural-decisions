-- ============================================================
-- C1300S2 | sql-server-index-audit
-- File   : 01_clustered_vs_nonclustered.sql
-- Topic  : Clustered vs Non-Clustered Index Behavior
-- System : STN_Lab - Sistema Tributario Nacional (Lab)
-- Author : C13 | Carlos Roberto
-- ============================================================
-- ESTRUCTURA CONFIRMADA - Contribuyentes
--   index_id 1 : PK_Contribuyente     CLUSTERED     - ContribuyenteID (int)
--   index_id 2 : IX_Contribuyente_NIT NONCLUSTERED  - NIT
--   index_id 4 : IX_Contribuyente_NIT_Covering NC   - NIT (cubierto)
--
-- IMPLICACIÓN:
--   Buscar por ContribuyenteID - Clustered Index Seek (clave real)
--   Buscar por NIT             - NC Index Seek + posible Key Lookup
-- ============================================================

USE STN_Lab;
GO

-- ============================================================
-- 1.0 - ENVIRONMENT CHECK
-- ============================================================

SELECT
    t.name        AS table_name,
    p.rows        AS row_count
FROM sys.tables t
JOIN sys.partitions p
    ON t.object_id = p.object_id
   AND p.index_id IN (0, 1)
WHERE t.name IN ('Contribuyente', 'Declaracion', 'Pago', 'Auditoria')
ORDER BY t.name;
GO

-- ============================================================
-- 1.1 - BASELINE: ESTADO ACTUAL DE ÍNDICES
-- ============================================================

SELECT
    i.index_id,
    i.name                          AS index_name,
    i.type_desc                     AS index_type,
    i.is_primary_key,
    STRING_AGG(c.name, ', ')
        WITHIN GROUP (ORDER BY ic.key_ordinal)
                                    AS key_columns
FROM sys.indexes i
JOIN sys.tables t
    ON i.object_id = t.object_id
JOIN sys.index_columns ic
    ON i.object_id = ic.object_id
   AND i.index_id  = ic.index_id
JOIN sys.columns c
    ON ic.object_id = c.object_id
   AND ic.column_id = c.column_id
WHERE t.name IN ('Contribuyente', 'Declaracion', 'Pago')
  AND ic.is_included_column = 0
GROUP BY i.index_id, i.name, i.type_desc, i.is_unique, i.is_primary_key
ORDER BY t.name, i.index_id;
GO

-- ============================================================
-- 1.2 - CLUSTERED INDEX SEEK POR CLAVE REAL (ContribuyenteID)
-- La clave clustered es ContribuyenteID (int), no NIT.
-- Buscar por esta columna garantiza Clustered Index Seek puro:
-- el motor navega el B-tree y llega directo al dato.
-- Sin Key Lookup posible - el nivel hoja tiene toda la fila.
-- Esperado: Clustered Index Seek · reads = 2 a 4
-- ============================================================

SET STATISTICS IO ON;
SET STATISTICS TIME ON;

SELECT
    ContribuyenteID,
    NIT,
    RazonSocial,
    Estado
FROM dbo.Contribuyente
WHERE ContribuyenteID = 500;   -- reemplazar con ID existente en el lab

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-- OBSERVACIÓN 1.2
-- Registrar: logical reads · operador en el plan · ausencia de Key Lookup
-- reads_1.2 = _3__


-- ============================================================
-- 1.2B - NON-CLUSTERED SEEK POR NIT (lo que se vio antes)
-- NIT tiene su propio NC index. Al buscar por NIT el optimizador
-- usa ese índice - correcto. Pero si la query pide columnas
-- que no están en el NC (RazonSocial, Estado), hace Key Lookup
-- de vuelta al clustered por cada fila encontrada.
-- Esperado: NC Index Seek + Key Lookup (Nested Loops)
-- ============================================================

SET STATISTICS IO ON;
SET STATISTICS TIME ON;

SELECT
    ContribuyenteID,
    NIT,
    RazonSocial,
    Estado
FROM dbo.Contribuyente
WHERE NIT = '1234567-8';   -- reemplazar con NIT existente

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-- OBSERVACIÓN 1.2B
-- Comparar reads de 1.2 vs 1.2B.
-- El NC Seek es rápido para localizar, pero el Key Lookup
-- agrega costo por cada columna extra fuera del índice.
-- Esto es exactamente lo que IX_Contribuyente_NIT_Covering resuelve.
-- reads_1.2B = __3_


-- ============================================================
-- 1.2C - NC COVERING SEEK POR NIT (índice cubierto existente)
-- IX_Contribuyente_NIT_Covering ya existe en el lab.
-- Si cubre las columnas de la query, el Key Lookup desaparece.
-- Verificar qué columnas INCLUDE tiene antes de ejecutar.
-- ============================================================

-- Primero: ver qué columnas cubre el índice existente
SELECT
    i.name                  AS index_name,
    c.name                  AS column_name,
    ic.is_included_column,
    ic.key_ordinal
FROM sys.indexes i
JOIN sys.index_columns ic
    ON i.object_id = ic.object_id
   AND i.index_id  = ic.index_id
JOIN sys.columns c
    ON ic.object_id = c.object_id
   AND ic.column_id = c.column_id
WHERE i.object_id = OBJECT_ID('dbo.Contribuyente')
  AND i.name = 'IX_Contribuyente_NIT_Covering'
ORDER BY ic.is_included_column, ic.key_ordinal;
GO

SET STATISTICS IO ON;
SET STATISTICS TIME ON;

SELECT
    ContribuyenteID,
    NIT,
    RazonSocial,
    Estado
FROM dbo.Contribuyente
WHERE NIT = '1234567-8';   -- mismo NIT que 1.2B

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-- OBSERVACIÓN 1.2C
-- Si el covering index incluye RazonSocial y Estado:
--   - El plan muestra solo NC Index Seek, sin Key Lookup
--   - Los reads deberían ser iguales o menores que 1.2B
-- Si el Key Lookup persiste: el covering index no cubre
--   las columnas pedidas - tema central del script 02.
-- reads_1.2C = ___


-- ============================================================
-- 1.3 - CLUSTERED INDEX RANGE SCAN
-- Rango sobre ContribuyenteID (clave clustered).
-- Las filas están ordenadas físicamente - lectura contigua.
-- Esperado: Clustered Index Seek con predicado de rango
-- ============================================================

SET STATISTICS IO ON;

SELECT
    ContribuyenteID,
    NIT,
    RazonSocial,
    Estado
FROM dbo.Contribuyente
WHERE ContribuyenteID BETWEEN 1 AND 1000;

SET STATISTICS IO OFF;
GO

-- OBSERVACIÓN 1.3
-- Observar estimated vs actual rows.
-- Si difieren mucho: estadísticas desactualizadas.
-- reads_1.3 = _10__


-- ============================================================
-- 1.4 - NON-CLUSTERED BASELINE SIN ÍNDICE (Estado)
-- Estado no tiene índice dedicado (no aparece en 1.1).
-- El optimizador lee todas las páginas del clustered.
-- Esperado: Clustered Index Scan · reads altos
-- ============================================================

SET STATISTICS IO ON;

SELECT
    ContribuyenteID,
    NIT,
    RazonSocial,
    Estado
FROM dbo.Contribuyente
WHERE Estado = 'ACTIVO';

SET STATISTICS IO OFF;
GO

-- OBSERVACIÓN 1.4 - BASELINE
-- Este número es el costo real de no tener índice en Estado.
-- reads_1.4 = _1087__ (BASELINE - full scan)


-- ============================================================
-- 1.5 - CREAR NC INDEX EN Estado
-- ============================================================

CREATE NONCLUSTERED INDEX IX_Contribuyente_Estado
    ON dbo.Contribuyente (Estado);
GO


-- ============================================================
-- 1.6 - NC SEEK + KEY LOOKUP (Estado con índice)
-- Mismo query que 1.4. El optimizador ahora puede usar el NC.
-- Pero RazonSocial y NIT no están en el índice - Key Lookup.
-- ============================================================

SET STATISTICS IO ON;

SELECT
    ContribuyenteID,
    NIT,
    RazonSocial,
    Estado
FROM dbo.Contribuyente
WHERE Estado = 'ACTIVO';

SET STATISTICS IO OFF;
GO

-- OBSERVACIÓN 1.6
-- Comparar reads_1.4 vs reads_1.6.
-- Pregunta de arquitecto: si el 80% son ACTIVO, el optimizador
-- puede ignorar el NC y hacer Scan de todas formas.
-- reads_1.6 = __2_
-- ¿Usó el NC o hizo Scan? - ___


-- ============================================================
-- 1.7 - DECLARACIONES: ESCENARIO REAL STN
-- ============================================================

-- 1.7.1 Ver índices actuales en Declaracion
SELECT
    i.index_id,
    i.name,
    i.type_desc,
    STRING_AGG(c.name, ', ') WITHIN GROUP (ORDER BY ic.key_ordinal) AS key_columns
FROM sys.indexes i
JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id
JOIN sys.columns c        ON ic.object_id = c.object_id AND ic.column_id = c.column_id
WHERE i.object_id = OBJECT_ID('dbo.Declaracion')
  AND ic.is_included_column = 0
GROUP BY i.index_id, i.name, i.type_desc
ORDER BY i.index_id;
GO

-- 1.7.2 Sin índice en ContribuyenteID - baseline
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

-- reads_1.7.2 = ___

-- 1.7.3 Crear NC index en ContribuyenteID
CREATE NONCLUSTERED INDEX IX_Declaracion_Contribuyente
    ON dbo.Declaracion (ContribuyenteID);
GO

-- 1.7.4 Re-ejecutar - NC Seek + Key Lookup por PeriodoFiscal y MontoDeclarado
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

-- reads_1.7.4 = _12__
-- OBSERVACIÓN: el Seek encontró rápido, pero pagó Key Lookup
-- por cada columna fuera del índice. Script 02 resuelve esto.


-- ============================================================
-- 1.8 - FORZAR OPERADORES (solo laboratorio)
-- ============================================================

-- Forzar Clustered Index Scan
SET STATISTICS IO ON;

SELECT DeclaracionID, ContribuyenteID, PeriodoFiscal, MontoDeclarado
FROM dbo.Declaracion WITH (INDEX = 1)
WHERE ContribuyenteID = 500;

SET STATISTICS IO OFF;
GO

-- Forzar NC index explícito
SET STATISTICS IO ON;

SELECT DeclaracionID, ContribuyenteID, PeriodoFiscal, MontoDeclarado
FROM dbo.Declaracion WITH (INDEX = IX_Declaracion_Contribuyente)
WHERE ContribuyenteID = 500;

SET STATISTICS IO OFF;
GO


-- ============================================================
-- 1.9 - CLEANUP
-- Ejecutar después de registrar todas las observaciones.
-- ============================================================

/*
DROP INDEX IF EXISTS IX_Contribuyente_Estado   ON dbo.Contribuyente;
DROP INDEX IF EXISTS IX_Declaracion_Contribuyente ON dbo.Declaracion;
*/
