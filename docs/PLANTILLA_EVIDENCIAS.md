# Plantilla de evidencias — PoC Bre-B · Pagos Programados (ejecución EN VIVO en AWS)

> Rellena esta plantilla al ejecutar la PoC real de **20.000 pagos a 10–15 TPS** con la
> arquitectura **Step Functions + Map distribuido**. Cada sección indica el **comando** que
> genera el dato, **dónde** tomar la captura y el **hueco** para pegar el valor medido.
> Al terminar, copia las tablas rellenas a la sección 17 del documento (y reemplaza las
> cifras en rojo del simulador por las medidas reales).

- **Cuenta:** `________________`  ·  **Región:** `us-east-2` (Ohio)
- **Fecha/hora de ejecución (6:00 a.m. simulada):** `________________`
- **run_id de la ejecución:** `________________`
- **Commit del repo desplegado:** `________________`  (`git rev-parse --short HEAD`)

---

## 0. Despliegue y validación previa (reproducible, sin costo)

```bash
./scripts/validate_dosing.sh          # simulador determinista: 20k @ 10–15 TPS
cd terraform && terraform init && terraform apply -auto-approve
```

- [ ] `terraform apply` → `Apply complete!` (captura de la salida)
- [ ] Outputs guardados (`terraform output`): `state_machine_arn`, `data_bucket`, `idempotency_table`, `state_machine_console_url`

---

## 1. Disparo del lote de 20.000 pagos (ASR-1)

```bash
./scripts/run_sfn.sh 20000            # escenario NORMAL (20.000 pagos)
# anota el run_id que imprime y el tiempo total (makespan)
```

| Dato | Comando / fuente | Valor medido | Objetivo |
|------|------------------|--------------|----------|
| run_id | salida de `run_sfn.sh` | `__________` | — |
| Estado de la ejecución | Step Functions → Executions | `SUCCEEDED` | SUCCEEDED |
| Duración del lote (makespan) | `run_sfn.sh` (segundos) | `______ s = ___ min` | ≤ 60 min |
| Pagos procesados OK | Map → ítems SUCCEEDED | `__________` | 20.000 |
| % completado en la ventana | makespan vs 3600 s | `______ %` | ≥ 99 % |

**Capturas (Figura — Step Functions):**
- [ ] Consola Step Functions → **Graph view** del Map distribuido (muestra concurrencia)
- [ ] Pestaña **Executions** con el estado `SUCCEEDED` y la duración
- [ ] **Map Run** → conteo de ítems `SUCCEEDED` / `FAILED`

---

## 2. Throughput y latencia (ASR-1 · banda 10–15 TPS)

```bash
./scripts/metrics.sh 60               # throughput, p95 y error rate del worker
```

| Métrica | Fuente | Valor medido | Objetivo |
|---------|--------|--------------|----------|
| Throughput sostenido | CloudWatch (invocaciones worker / s) | `______ TPS` | 10–15 TPS |
| Throughput pico | CloudWatch (minuto pico) | `______ TPS` | ≤ 15 TPS (dosificado) |
| Latencia p95 por pago | X-Ray / CloudWatch Duration p95 | `______ ms` | ≤ 2 s |
| Error rate | CloudWatch Logs Insights | `______ %` | < 1 % |

**Capturas (Figura — CloudWatch dashboard `breb-poc-sfn-dashboard`):**
- [ ] Widget **Throughput — invocaciones del worker (banda 10–15 TPS)**
- [ ] Widget **Latencia p95 del worker (≤ 2 s)**
- [ ] Widget **Ejecuciones de la máquina de estados (iniciadas/OK/fallidas)**
- [ ] Widget **Errores del worker (error rate < 1 %)**

---

## 3. Integridad: 0 pérdidas / 0 duplicados (ASR-2)

```bash
./scripts/verify_sfn.sh <run_id>      # idempotencia + manifiesto del Map en S3
```

| Dato | Fuente | Valor medido | Objetivo |
|------|--------|--------------|----------|
| payment_key únicos en DynamoDB | `verify_sfn.sh` / scan COUNT | `__________` | = pagos únicos |
| Pagos duplicados ejecutados | Map (DUPLICATE_SKIPPED vs ejecutados) | `0` | 0 |
| Resultados en S3 (manifest.json) | `s3://<data_bucket>/resultados/<run_id>/` | `SUCCEEDED/FAILED` | presente |

**Capturas (Figura — ASR-2):**
- [ ] **DynamoDB → `breb-poc-idempotency` → Explore items**: un ítem por `payment_key`, `status = DONE`
- [ ] **S3 → `resultados/<run_id>/manifest.json`**: resumen de éxitos/fallos del Map
- [ ] **X-Ray → Service map**: `worker → stub-backend → DynamoDB`

---

## 4. Escenario conservador (borde inferior · 10 TPS)

```bash
# Baja el ritmo objetivo a 10 TPS y vuelve a disparar
cd terraform && terraform apply -auto-approve -var 'sfn_target_tps=10'
cd .. && ./scripts/run_sfn.sh 20000
```

| Dato | Valor medido | Objetivo |
|------|--------------|----------|
| Throughput sostenido | `______ TPS` | ≈ 10 TPS |
| Duración del lote | `______ min` | ≈ 33 min (≤ 60) |

---

## 5. Escenario de fallo transitorio + duplicados (ASR-2)

```bash
./scripts/run_sfn.sh 20000 50         # 1 de cada 50 pagos duplicado (~399)
./scripts/verify_sfn.sh <run_id>
```

| Dato | Valor medido | Objetivo |
|------|--------------|----------|
| Pagos únicos ejecutados | `__________` | ≈ 19.601 |
| Duplicados omitidos | `__________` | ≈ 399 |
| Fallos permanentes (a resultado FAILED) | `__________` | reintentados antes |
| Alarma `breb-poc-sfn-failed` | `OK / ALARM` | controlada |

**Capturas:**
- [ ] Logs del worker con eventos `duplicate_skipped`
- [ ] CloudWatch → **All alarms** (`breb-poc-sfn-failed`)

---

## 6. Tabla final para pegar en el documento (sección 17.3 / veredicto)

> Reemplaza en el Word las cifras en rojo del simulador por estas, ya medidas en AWS.

| ASR | Criterio de éxito | Resultado medido (PoC en vivo) | Veredicto |
|-----|-------------------|--------------------------------|-----------|
| ASR-1 · Desempeño | 10–15 TPS · p95 ≤ 2 s · ≥ 99 % en ≤ 60 min (20.000 pagos) | `____ TPS · p95 ____ ms · ____ min` | `CUMPLIDO ✅` |
| ASR-2 · Integridad | 0 pérdidas · 0 duplicados · error rate < 1 % | `____ únicos · 0 dup · ____ %` | `CUMPLIDO ✅` |

---

## 7. Enlaces de evidencia

- Repositorio: https://github.com/vimapeco24/ArquitecturaCloudPoc
- Consola Step Functions: `terraform output -raw state_machine_console_url`
- Dashboard CloudWatch: `https://us-east-2.console.aws.amazon.com/cloudwatch/home?region=us-east-2#dashboards:name=breb-poc-sfn-dashboard`
- Video de la PoC (2–3 min): `https://youtu.be/__________`

---

## 8. Limpieza

```bash
cd terraform && terraform destroy -auto-approve
```
- [ ] `Destroy complete!` (captura)
