CREATE     PROCEDURE dbo.reglamentointerno_controlarDocumentos
@CODIGO BIGINT, 
  @TIPO_TRAMITE INT, 
  @ESTADO TINYINT, 
  @FASE INT,
  @USUARIO INT, 
  @USUARIO_RESPONSABLE INT, 
  @USUARIO_SOLICITANTE INT
AS
BEGIN

  /* 
    Autora: Dayana Fernández
    Trámite: APROBACIÓN DE REGLAMENTO INTERNO DE TRABAJO
    Modificado por: Samantha Mejía 
    Fecha: 23/02/2026
  */

  SET NOCOUNT ON;

  -------------------------------------------------------------------------
  -- Precondiciones
  -------------------------------------------------------------------------
  IF @USUARIO NOT IN (@USUARIO_SOLICITANTE, @USUARIO_RESPONSABLE) RETURN;
  IF OBJECT_ID('tempdb..#DOC') IS NULL RETURN;

  DECLARE @EsResp BIT = CASE WHEN @USUARIO=@USUARIO_RESPONSABLE THEN 1 ELSE 0 END;
  DECLARE @EsSol  BIT = CASE WHEN @USUARIO=@USUARIO_SOLICITANTE THEN 1 ELSE 0 END;
  DECLARE @EnPrep BIT = CASE WHEN @ESTADO=0 THEN 1 ELSE 0 END;

  -------------------------------------------------------------------------
  -- Condiciones específicas del nuevo trámite
  -------------------------------------------------------------------------
  DECLARE 
    @CONSTANCIA_DIRSAC INT = 7,
    @CONSTANCIA_CONSUCOOP INT = 8,
    @CONSTANCIA_SERVICIOCIVIL INT = 9,
    @COPIA_FOTOESTATICA INT = 10,
    @TIPO_EMPRESA VARCHAR(255),
    @TIPO_REGLAMENTO VARCHAR(255);
    

  -- Obtener tipo de empresa y reglamento
  SELECT 
    @TIPO_EMPRESA = TRIM(tipo_empresa), 
    @TIPO_REGLAMENTO = TRIM(tipo_reglamento)
  FROM dbo.datos_adicionales_1 WITH (NOLOCK)
  WHERE codigo_tramite = @CODIGO;

  -------------------------------------------------------------------------
  -- 1) Config aplicable (fase > estado > desde_inicio)
  -------------------------------------------------------------------------
  IF OBJECT_ID('tempdb..#CFG_APLICA') IS NOT NULL DROP TABLE #CFG_APLICA;
  CREATE TABLE #CFG_APLICA
  (
    codigo_molde           INT  NOT NULL PRIMARY KEY,
    editable_solicitante   BIT  NULL,
    editable_responsable   BIT  NULL,
    codigo_obligatoriedad  INT  NOT NULL,
    visibilidad            BIT  NULL
  );

  ;WITH P AS (
    SELECT
      p.codigo_molde,
      p.editable_solicitante,
      p.editable_responsable,
      ISNULL(p.codigo_obligatoriedad, 0) AS codigo_obligatoriedad,
      p.visibilidad,
      ROW_NUMBER() OVER (
        PARTITION BY p.codigo_molde
        ORDER BY
          CASE WHEN p.codigo_fase   = @FASE   THEN 3
               WHEN p.codigo_estado = @ESTADO THEN 2
               WHEN p.desde_inicio  = 1       THEN 1
               ELSE 0 END DESC,
          p.fecha_ultima_modificacion DESC
      ) AS rn
    FROM dbo.tramite_molde_parametrizacion p WITH (NOLOCK)
    WHERE p.codigo_tipo_tramite = @TIPO_TRAMITE
      AND (p.codigo_fase = @FASE OR p.codigo_estado = @ESTADO OR p.desde_inicio = 1)
  )
  INSERT INTO #CFG_APLICA(codigo_molde, editable_solicitante, editable_responsable, codigo_obligatoriedad, visibilidad)
  SELECT codigo_molde, editable_solicitante, editable_responsable, codigo_obligatoriedad, visibilidad
  FROM P
  WHERE rn = 1;

  -----------------------------------------------------------------------
-- PUBLICACIÓN CONTROLADA (sin IDs de fase):
-- 2089 se muestra al ciudadano SOLO si:
--   1) La configuración (tabla) en esta fase/estado lo permite (visibilidad=1)
--   2) Existe archivo real (no STUB)
--   3) Está revisado/firmado (revisado_por y fecha_revision no NULL)
-----------------------------------------------------------------------
DECLARE @MOLDE_RECURSO INT = 2089;
DECLARE @VisCfg BIT = 0;

SELECT @VisCfg = ISNULL(c.visibilidad, 0)
FROM #CFG_APLICA c
WHERE c.codigo_molde = @MOLDE_RECURSO;

UPDATE dt
   SET dt.visibilidad =
       CASE
         WHEN @VisCfg = 1
          AND dt.nombre_archivo IS NOT NULL
          AND dt.nombre_archivo <> '__STUB__.pdf'
          AND dt.revisado_por IS NOT NULL
          AND dt.fecha_revision IS NOT NULL
         THEN 1
         ELSE 0
       END
FROM dbo.documento_tramite dt
WHERE dt.codigo_tramite = @CODIGO
  AND dt.codigo_molde_documento = @MOLDE_RECURSO;

  -------------------------------------------------------------------------
  -- 2) #ALLOW por rol (qué moldes se muestran)
  -------------------------------------------------------------------------
  IF OBJECT_ID('tempdb..#ALLOW') IS NOT NULL DROP TABLE #ALLOW;
  CREATE TABLE #ALLOW(codigo_molde INT PRIMARY KEY, src CHAR(1));

  IF OBJECT_ID('tempdb..#DT') IS NOT NULL DROP TABLE #DT;
  SELECT DISTINCT codigo_molde_documento
  INTO #DT
  FROM dbo.documento_tramite WITH (NOLOCK)
  WHERE codigo_tramite = @CODIGO;


  
  IF @EsSol = 1
  BEGIN
    IF OBJECT_ID('tempdb..#CAND_SOL') IS NOT NULL DROP TABLE #CAND_SOL;
    SELECT c.* INTO #CAND_SOL
    FROM #CFG_APLICA c
    WHERE ISNULL(c.visibilidad,0) = 1;

    INSERT INTO #ALLOW(codigo_molde, src)
    SELECT codigo_molde, 'C' FROM #CAND_SOL
    WHERE codigo_molde NOT IN (
    @CONSTANCIA_DIRSAC,
    @CONSTANCIA_CONSUCOOP,
    @CONSTANCIA_SERVICIOCIVIL,
    @COPIA_FOTOESTATICA
);
  END
 ELSE
BEGIN
  -- Base visible para funcionario (misma poda de especiales)
  INSERT INTO #ALLOW(codigo_molde, src)
  SELECT f.codigo_molde, 'C'
  FROM #CFG_APLICA f
  WHERE f.codigo_molde NOT IN (
    @CONSTANCIA_DIRSAC,
    @CONSTANCIA_CONSUCOOP,
    @CONSTANCIA_SERVICIOCIVIL,
    @COPIA_FOTOESTATICA
  );
END

  -- Agregar moldes específicos según tipo_empresa y tipo_reglamento
  IF @TIPO_EMPRESA IN ('Asociación Civil', 'Fundación', 'ONG') AND NOT EXISTS(SELECT 1 FROM #ALLOW WHERE codigo_molde = @CONSTANCIA_DIRSAC)
    INSERT INTO #ALLOW(codigo_molde, src) VALUES (@CONSTANCIA_DIRSAC, 'E');

  IF @TIPO_EMPRESA IN ('Cooperativa de Ahorro') AND NOT EXISTS(SELECT 1 FROM #ALLOW WHERE codigo_molde = @CONSTANCIA_CONSUCOOP)
    INSERT INTO #ALLOW(codigo_molde, src) VALUES (@CONSTANCIA_CONSUCOOP, 'E');

  IF @TIPO_EMPRESA IN ('Institución del Estado (descentralizada)') AND NOT EXISTS(SELECT 1 FROM #ALLOW WHERE codigo_molde = @CONSTANCIA_SERVICIOCIVIL)
    INSERT INTO #ALLOW(codigo_molde, src) VALUES (@CONSTANCIA_SERVICIOCIVIL, 'E');

  IF @TIPO_REGLAMENTO IN ('Reforma parcial', 'Reforma total') AND NOT EXISTS(SELECT 1 FROM #ALLOW WHERE codigo_molde = @COPIA_FOTOESTATICA)
    INSERT INTO #ALLOW(codigo_molde, src) VALUES (@COPIA_FOTOESTATICA, 'E');
  
-----------------------------------------------------------------------
-- FILTRO: Solo permitir el molde de Resoluciones* correspondiente al tipo de trámite
-----------------------------------------------------------------------

-- Declaración de códigos de resoluciones 
DECLARE @reforma_total INT = 19;
DECLARE @reforma_parcial INT = 21;
DECLARE @reforma_incial INT = 23;
DECLARE @trascripcion_total INT = 20; 
DECLARE @trascripcion_parcial INT = 22;
DECLARE @trascripcion_inicial INT = 24; 
DECLARE @resolucion_reposicion INT = 2089;


-- Determinar molde según el tipo de trámite

DECLARE @Molde_RES INT = NULL;
DECLARE @Molde_TRA int = null;
IF @TIPO_TRAMITE = 1 -- Solo aplica para Certificaciones y Constancias
BEGIN
    DECLARE @tipo NVARCHAR(255);

    SELECT @tipo = tipo_reglamento
    FROM dbo.datos_adicionales_1 WITH (NOLOCK)
    WHERE codigo_tramite = @CODIGO;

    IF @tipo LIKE 'Reforma total%'    SET @Molde_RES = @reforma_total;
    IF @tipo LIKE 'Reforma parcial%'  SET @Molde_RES = @reforma_parcial;   
    IF @tipo LIKE 'Nuevo reglamento%' SET @Molde_RES = @reforma_incial;

    -- Eliminar todos los moldes T1–T5 excepto el correspondiente
    DELETE FROM #ALLOW
    WHERE codigo_molde IN (@reforma_total, @reforma_parcial, @reforma_incial)
      AND codigo_molde <> @Molde_RES;
END 
END
IF @TIPO_TRAMITE = 1 -- Solo aplica para Certificaciones y Constancias
BEGIN

    SELECT @tipo = tipo_reglamento
    FROM dbo.datos_adicionales_1 WITH (NOLOCK)
    WHERE codigo_tramite = @CODIGO;

    IF @tipo LIKE 'Reforma total%'    SET @Molde_TRA = @trascripcion_total;
    IF @tipo LIKE 'Reforma parcial%'  SET @Molde_TRA = @trascripcion_parcial;   
    IF @tipo LIKE 'Nuevo reglamento%' SET @Molde_TRA = @trascripcion_inicial;

    -- Eliminar todos los moldes T1–T5 excepto el correspondiente
    DELETE FROM #ALLOW
    WHERE codigo_molde IN (@trascripcion_total, @trascripcion_parcial, @trascripcion_inicial)
      AND codigo_molde <> @Molde_TRA;
END 



  -------------------------------------------------------------------------
  -- NUEVO: forzar inclusión de moldes negativos en #ALLOW
  -------------------------------------------------------------------------
  INSERT INTO #ALLOW(codigo_molde, src)
  SELECT DISTINCT d.codigo_molde_documento, 'N'
  FROM #DT d
  WHERE d.codigo_molde_documento < 0
    AND NOT EXISTS (
      SELECT 1 FROM #ALLOW a WHERE a.codigo_molde = d.codigo_molde_documento
    );

  
  
  -------------------------------------------------------------------------
  -- 3) Poda de #DOC a lo permitido (sin borrar existentes)
  -------------------------------------------------------------------------
 DELETE D
FROM #DOC D
LEFT JOIN #ALLOW A ON A.codigo_molde = D.codigo_molde_documento
WHERE D.codigo_molde_documento IS NOT NULL
  AND D.codigo_molde_documento >= 0
  AND (
        -- Eliminar sólo si es stub y no está permitido
        (D.nombre_archivo = '__STUB__.pdf' AND A.codigo_molde IS NULL)
        -- Eliminar si no permitido y no tiene documento real
        OR (A.codigo_molde IS NULL AND (D.nombre_archivo IS NULL OR D.nombre_archivo = '__STUB__.pdf'))
      );


  -------------------------------------------------------------------------
  -- 4) Sembrar faltantes en #DOC
  -------------------------------------------------------------------------
  INSERT INTO #DOC
  (
    codigo_molde_documento, nombre, obligatorio, editable, visibilidad,
    tiene_formato, orden, nombre_molde, nombre_archivo, tiene_campos_reemplazables,
    sp_campos_reemplazables, firma_obligatoria, generar_documento_descargar,
    largo_maximo
  )
  SELECT
    md.codigo_molde_documento,
    md.nombre_molde,
    0,
    CASE WHEN @EsSol=1 THEN CASE WHEN @EnPrep=1 THEN 1 ELSE 0 END ELSE 1 END,
    CASE WHEN @EsSol=1 THEN 0 ELSE 1 END,
    CASE WHEN md.documento_molde IS NULL THEN 0 ELSE 1 END,
    ISNULL(md.orden, 1000),
    md.nombre_molde,
    md.nombre_archivo,
    ISNULL(md.tiene_campos_reemplazables,0),
    md.sp_campos_reemplazables,
    ISNULL(md.firma_obligatoria,0),
    ISNULL(md.generar_documento_descargar,0),
    ISNULL(md.largo_maximo,0)
  FROM #ALLOW a
  JOIN dbo.molde_documento_tramite md WITH (NOLOCK)
    ON md.codigo_tipo_tramite = @TIPO_TRAMITE
   AND md.codigo_molde_documento = a.codigo_molde
  WHERE md.activo = 1
    AND NOT EXISTS (SELECT 1 FROM #DOC d WHERE d.codigo_molde_documento = md.codigo_molde_documento);
  
    -------------
   -------------------------------------------------------------------------
  -- 4A) Sincronizar documentos reales desde documento_tramite hacia #DOC
  --     (para que tanto ciudadano como responsable vean el archivo cargado)
  -------------------------------------------------------------------------

    -- a) Actualizar filas ya existentes en #DOC con el archivo real
  UPDATE D
    SET D.codigo_documento = dt.codigo_documento,
        D.nombre_archivo   = dt.nombre_archivo
  FROM #DOC D
  JOIN dbo.documento_tramite dt WITH (NOLOCK)
       ON dt.codigo_tramite          = @CODIGO
      AND dt.codigo_molde_documento = D.codigo_molde_documento
  WHERE dt.nombre_archivo IS NOT NULL
    AND dt.nombre_archivo <> '__STUB__.pdf';

  -- b) Insertar en #DOC los documentos reales que aún no tengan fila
  INSERT INTO #DOC
  (
    codigo_documento,
    codigo_molde_documento,
    nombre,
    obligatorio,
    editable,
    visibilidad,
    tiene_formato,
    orden,
    nombre_molde,
    nombre_archivo,
    tiene_campos_reemplazables,
    sp_campos_reemplazables,
    firma_obligatoria,
    generar_documento_descargar,
    largo_maximo
  )
  SELECT
    dt.codigo_documento,
    md.codigo_molde_documento,
    md.nombre_molde,
    0,                                  -- obligatorio se ajusta en el bloque 5
    0,                                  -- editable se ajusta por rol (bloque 5)
    CASE WHEN ISNULL(dt.visibilidad,0)=1 THEN 1 ELSE 0 END,
    CASE WHEN md.documento_molde IS NULL THEN 0 ELSE 1 END,
    ISNULL(md.orden, 1000),
    md.nombre_molde,
    dt.nombre_archivo,                  -- *** archivo REAL cargado ***
    ISNULL(md.tiene_campos_reemplazables,0),
    md.sp_campos_reemplazables,
    ISNULL(md.firma_obligatoria,0),
    ISNULL(md.generar_documento_descargar,0),
    ISNULL(md.largo_maximo,0)
  FROM dbo.documento_tramite dt WITH (NOLOCK)
  JOIN dbo.molde_documento_tramite md WITH (NOLOCK)
       ON md.codigo_tipo_tramite     = @TIPO_TRAMITE
      AND md.codigo_molde_documento = dt.codigo_molde_documento
  JOIN #ALLOW a
       ON a.codigo_molde = md.codigo_molde_documento
  WHERE dt.codigo_tramite = @CODIGO
    AND dt.nombre_archivo IS NOT NULL
    AND dt.nombre_archivo <> '__STUB__.pdf'
    AND NOT EXISTS (
          SELECT 1
          FROM #DOC d
          WHERE d.codigo_documento = dt.codigo_documento
        );
  ---------------------------------------------------------------------------
-- 4B) Para el ciudadano: Control estricto de documentos de gestión interna
-- No mostrar si: 
--    1. No hay archivo real (Placeholder/Stub)
--    2. EXISTE archivo pero la FASE ACTUAL no permite su visibilidad
---------------------------------------------------------------------------
IF @EsSol = 1
BEGIN
    DELETE D
    FROM #DOC D
    LEFT JOIN #CFG_APLICA F ON F.codigo_molde = D.codigo_molde_documento
    WHERE D.codigo_molde_documento IN (@reforma_total, @reforma_parcial, @reforma_incial, @trascripcion_total, @trascripcion_parcial, @trascripcion_inicial, @resolucion_reposicion)
      AND (
           -- Caso A: No hay archivo cargado aún
           D.codigo_documento IS NULL 
           OR D.nombre_archivo IS NULL 
           OR D.nombre_archivo = '__STUB__.pdf'
           
           OR 
           
           -- Caso B: Hay archivo, pero la configuración de la FASE ACTUAL dice que NO es visible
           ISNULL(F.visibilidad, 0) = 0
          );
END

---------------------------------------------------------------------------
-- 4B.1) Ciudadano: apagar visibilidad si la tabla NO lo permite
-- (sin borrar filas, evita que desaparezca cuando sí debe verse)
---------------------------------------------------------------------------
IF @EsSol = 1
BEGIN
    UPDATE D
       SET D.visibilidad = 0
    FROM #DOC D
    LEFT JOIN #CFG_APLICA F ON F.codigo_molde = D.codigo_molde_documento
    WHERE D.codigo_molde_documento = 2089
      AND (F.codigo_molde IS NOT NULL AND ISNULL(F.visibilidad,0) = 0);
END


  -------------------------------------------------------------------------
  -- 5) Aplicar reglas por rol y OBLIGATORIEDAD
  -------------------------------------------------------------------------
  IF OBJECT_ID('tempdb..#FLAGS') IS NOT NULL DROP TABLE #FLAGS;
  SELECT
    c.codigo_molde,
    c.editable_solicitante,
    c.editable_responsable,
    c.codigo_obligatoriedad,
    c.visibilidad
 INTO #FLAGS
  FROM #CFG_APLICA c;

  IF @EsSol = 1
  BEGIN
    UPDATE #DOC SET editable = 0 WHERE codigo_documento IS NOT NULL;

    UPDATE D
  SET D.visibilidad = CASE WHEN ISNULL(dt.visibilidad, 0) = 1 THEN 1 ELSE 0 END,
      D.editable    = CASE 
                        WHEN @EnPrep = 0 THEN 0
                        WHEN F.codigo_obligatoriedad = 12 THEN 0
                        ELSE COALESCE(F.editable_solicitante, 1)
                      END,
      D.obligatorio = CASE 
                        WHEN @EnPrep = 1 AND F.codigo_obligatoriedad IN (1,8,11,13) THEN 1
                        WHEN @ESTADO = 4 AND F.codigo_obligatoriedad IN (9,10,11,13) THEN 1
                        ELSE 0
                      END
FROM #DOC D
JOIN #ALLOW A ON A.codigo_molde = D.codigo_molde_documento
JOIN #FLAGS F ON F.codigo_molde = D.codigo_molde_documento
LEFT JOIN dbo.documento_tramite dt WITH (NOLOCK)
       ON dt.codigo_tramite = @CODIGO
      AND dt.codigo_molde_documento = D.codigo_molde_documento;
--
  END
  ELSE
  BEGIN
    UPDATE D
      SET D.visibilidad = 1,
          D.editable    = CASE
                            WHEN F.codigo_obligatoriedad = 12 THEN 0
                            ELSE COALESCE(F.editable_responsable, 1)
                          END,
          D.obligatorio = CASE
                            WHEN @ESTADO = 4 AND F.codigo_obligatoriedad BETWEEN 2 AND 7 THEN 1
                            ELSE 0
                          END
    FROM #DOC D
    JOIN #ALLOW A ON A.codigo_molde = D.codigo_molde_documento
    JOIN #FLAGS F ON F.codigo_molde = D.codigo_molde_documento;
  END

  -------------------------------------------------------------------------
  -- 6) Anti-alerta del motor: STUB PDF
  -------------------------------------------------------------------------
  DECLARE @stub_inserts INT = 0, @stub_clean INT = 0;

  ;WITH OBL_MOTOR AS (
    SELECT
      md.codigo_molde_documento AS codigo_molde,
      md.nombre_molde,
      md.obligatorio            AS oblig_nativo
    FROM dbo.molde_documento_tramite md WITH (NOLOCK)
    WHERE md.codigo_tipo_tramite = @TIPO_TRAMITE
      AND md.activo = 1
  ),
  BASE AS (
    SELECT
      m.codigo_molde,
      m.nombre_molde,
      m.oblig_nativo,
      COALESCE(f.codigo_obligatoriedad, 0) AS oblig_cfg,
      CASE WHEN d.codigo_molde_documento IS NULL THEN 1 ELSE 0 END AS falta_archivo
    FROM OBL_MOTOR m
    LEFT JOIN #FLAGS f ON f.codigo_molde = m.codigo_molde
    LEFT JOIN #DT   d ON d.codigo_molde_documento = m.codigo_molde
  ),
  FALTAN AS (
    SELECT *
    FROM BASE b
    WHERE b.falta_archivo = 1
      AND (
            (
              (
                (@EsSol=1 AND @EnPrep=1 AND b.oblig_nativo IN (1,8,11,13)) OR
                (@EsSol=1 AND @ESTADO=4 AND b.oblig_nativo IN (9,10,11,13)) OR
                (@EsResp=1 AND @ESTADO=4 AND b.oblig_nativo BETWEEN 2 AND 7)
              )
              AND COALESCE(b.oblig_cfg, 0) IN (0,7,8,10,11)
            )
            OR
            (
              @EsResp=1 AND @ESTADO=4
              AND COALESCE(b.oblig_cfg, 0) IN (0,7,8,10,11)
            )
          )
  )
  INSERT INTO dbo.documento_tramite
  (
    codigo_tramite, codigo_molde_documento, nombre, fecha,
 revisado_por, fecha_revision, puesto_por,
    visibilidad, nombre_archivo, documento
  )
  SELECT
    @CODIGO,
    x.codigo_molde,
    x.nombre_molde,
    SYSUTCDATETIME(),
    NULL,
    NULL,
    CASE WHEN @EsResp=1 THEN @USUARIO_RESPONSABLE ELSE @USUARIO_SOLICITANTE END,
    1,
    '__STUB__.pdf',
    0x255044462D312E300A255EFFFF0A25E2E3CFD30A
  FROM FALTAN x;

  SET @stub_inserts = @@ROWCOUNT;

  ;WITH DUPS AS (
    SELECT d.codigo_molde_documento, COUNT(*) AS c
    FROM dbo.documento_tramite d WITH (NOLOCK)
    WHERE d.codigo_tramite = @CODIGO
    GROUP BY d.codigo_molde_documento
   HAVING COUNT(*) > 1
  )
 DELETE s
  FROM dbo.documento_tramite s
  JOIN DUPS u ON u.codigo_molde_documento = s.codigo_molde_documento
  WHERE s.codigo_tramite = @CODIGO
    AND s.nombre_archivo = '__STUB__.pdf';

  SET @stub_clean = @@ROWCOUNT;

  -------------------------------------------------------------------------
  -- 7) Poda final de placeholders no permitidos en la UI
  -------------------------------------------------------------------------
  DELETE D
  FROM #DOC D
  LEFT JOIN #ALLOW A ON A.codigo_molde = D.codigo_molde_documento
  WHERE D.codigo_documento IS NULL
    AND D.codigo_molde_documento IS NOT NULL
    AND D.codigo_molde_documento >= 0   -- NUEVO: no borrar placeholders de moldes negativos
    AND A.codigo_molde IS NULL;
  
  IF @EsSol = 1
  BEGIN
    DELETE D
    FROM #DOC D
    LEFT JOIN #FLAGS F ON F.codigo_molde = D.codigo_molde_documento
    WHERE D.visibilidad = 0
      AND D.obligatorio = 0
      AND D.codigo_molde_documento >= 0  -- NUEVO: no ocultar negativos al solicitante
      AND (D.nombre_archivo IS NULL OR D.nombre_archivo = '__STUB__.pdf');
  END

