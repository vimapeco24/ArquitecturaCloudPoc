# Registro de trabajo — Entrega 2 Bre-B (handoff de contexto)

> Archivo para retomar el trabajo con todo el contexto. Última actualización: 2026-11-03.

## Documentos de salida (entregables)
- **Documento final:** `221026/GloMo - Pagos recurrentes Bre B.docx` (+ su PDF `.pdf`).
  ESTE es el entregable. Los `*_BACKUP_*.docx/.pdf` son copias de seguridad, ignorar.
- **Requisitos Entrega 2:** `221026/Entrega 2 - Proyecto ARTI4207-2026-20.pdf`.
- **Comentarios de profesores (Entrega 1):** `221026/Proyecto ARTI 4207-2026-20.pdf` + notas
  que dio el usuario (ver sección "Comentarios profesores" abajo).

## Repo de la PoC
- GitHub: https://github.com/vimapeco24/ArquitecturaCloudPoc (rama main). YA SINCRONIZADO.
- Copia local: `221026/poc-breb-aws/` (mismo remoto).
- Push se hace con token del usuario (NO persistir en git config; el usuario debe revocarlo).

## Estado del EXPERIMENTO (PoC) — COMPLETO Y VERIFICADO ✅
Cuenta aftc_test (803647807230), región us-east-2 (Ohio). Ejecutado en CloudShell.
- **ASR-1 (desempeño):** 76,8 TPS pico · p95 3 ms/mensaje · 0 errores → OK.
- **ASR-2 (integridad):** cola y DLQ en 0 · idempotencia OK (1 item por clave) → OK.
- Inyección optimizada: de 256 s → ~1,3 s (load_fast.py boto3+hilos).
- Dosificado: max_concurrency=10 (event source mapping SQS→Lambda).

### Scripts del experimento (en el repo, en GitHub)
- `scripts/run_experiment.sh ESCENARIO [TOTAL]` — orquesta purga→carga→drenado→verify+metrics.
  Defaults rápidos: normal/fault=500, stress=1500. PURGE=0 salta el sleep de 60 s.
- `scripts/metrics.sh [MIN]` — TPS (mensajes/s pico), p95/mensaje, error rate desde CloudWatch.
- `scripts/verify.sh` — profundidad de colas, DLQ y conteo de idempotencia en DynamoDB.
- `load/load_fast.py` — inyector boto3+hilos (rápido). `load/load_cli.sh` — fallback AWS CLI.
- Comandos CloudShell:
  ```
  cd ~/ArquitecturaCloudPoc && git pull && chmod +x scripts/*.sh load/*.sh load/*.py
  cd terraform && terraform apply -auto-approve && cd ..
  ./scripts/run_experiment.sh normal
  PURGE=0 ./scripts/run_experiment.sh stress
  PURGE=0 ./scripts/run_experiment.sh fault
  ```

## Diagramas de la PoC (drawio + png, en repo y en el Word)
Todos con íconos AWS que SÍ renderizan en drawio CLI. OJO: `simple_queue_service`,
`cloudwatch_2`, `eventbridge_scheduler`, `distributed_load_testing` NO renderizan;
usar `queue`, `cloudwatch`, `eventbridge`, `users`.
- `BreB_PoC_AWS` — arquitectura (grilla limpia, iconos correctos). → Word Figura 12 (image16, rId21)
- `BreB_PoC_Secuencia` — secuencia UML E2E. → Word Figura 13 (image17, rId50)
- `BreB_PoC_Resultados` — tablero KPIs+gráficos+tabla (76,8 TPS, p95 3 ms). → Word Figura 14 (image18, rId51)
- `BreB_PoC_Idempotencia` — ASR-2, dos ramas separadas (A procesa / B omite). → Word Figura 15 (image19, rId52)
- `BreB_PoC_Runbook` — fases 0–8 del experimento. → Word Figura 16 (image20, rId53)

### Cómo insertar/actualizar una imagen en el Word (procedimiento probado)
1. `unzip -o "GloMo...docx" -d /tmp/dx`
2. copiar PNG a `/tmp/dx/word/media/imageN.png`
3. ajustar cx/cy del `<w:drawing>` de ese rId (cx=5760720, cy=cx*h/w)
4. re-zip: `zip -X /tmp/new.docx '[Content_Types].xml'` y luego `zip -X -r /tmp/new.docx . -x '[Content_Types].xml'`
5. validar XML, reemplazar el docx, regenerar PDF con `soffice --headless --convert-to pdf`
6. `pkill -f soffice` antes de convertir si da "source file could not be loaded".
7. Verificar: extraer imageN del docx y comparar md5 con el PNG del repo.

## Sección 17 del Word (PoC) — contenido actual
- 17.1 Alcance + Figura 12 (arquitectura) + Figura 13 (secuencia)
- 17.2 Plan de pruebas (tabla de escenarios)
- 17.3 Métricas: explicación de 3 escenarios + tabla de resultados reales +
  "Veredicto del experimento" (tabla ASR-1/ASR-2 CUMPLIDO) + Figura 14 (tablero)
- 17.4 Evidencia: bloque con salida real (76,8 TPS, etc.) + interpretación + Figura 15 (idempotencia)
- (17.5 ELIMINADA el 2026-11-03: el runbook paso-a-paso no corresponde al documento académico; vive solo en RUNBOOK_EXPERIMENTO.md del repo. La sección PoC del Word queda en 17.1–17.4, que es lo que pide la Entrega 2.)

## Comentarios de profesores (Entrega 1) — estado
- Volumetría: ETL + MAU → YA en tabla de volumetría (MAU ~3,2M, ETL incremental/hora).
- AS-IS: infra física + monitoreo e2e → YA (VMware, F5, VLAN/DMZ, Oracle RAC, Dynatrace/ELK/Zabbix).
- TO-BE: Direct Connect/VPN, VPC endpoint, BI, IA/ML → YA (canal dedicado+VPN HA+PrivateLink,
  GenAI/ML con casos de uso, stakeholders consumen BI). Diagrama BreB_TOBE_Agnostico_Corregido.
- Patrones App no visibles → YA etiquetados P/D/S en el TO-BE.
- Blueprints (textos/iconos/observabilidad) → YA corregidos (AWS y GCP, md5 verificado = en el Word).
- Costeo: enlaces calculadoras → YA (calculator.aws y cloud.google.com/products/calculator).

## PENDIENTES (dependen del usuario)
1. Grabar el VIDEO 2–3 min y reemplazar el placeholder `https://youtu.be/` en la sección 17.4.
2. REVOCAR el token de GitHub que se compartió en el chat (quedó expuesto).
3. Si el usuario ve una versión vieja de una figura: es CACHÉ del visor. El docx en disco
   (verificado por md5 y por render de la página del PDF) tiene siempre la última versión.
   Cerrar Word/Preview por completo (Cmd+Q) y reabrir. Si Word tenía el archivo abierto durante
   la regeneración, cerrar SIN guardar para no pisar los cambios.

## Nota técnica importante
- El `terraform.tfstate` vive en CloudShell (~/ArquitecturaCloudPoc/terraform), NO en local.
- El stub se invoca por lambda:InvokeFunction (NO Function URL) porque la org bloquea las URLs (403).
