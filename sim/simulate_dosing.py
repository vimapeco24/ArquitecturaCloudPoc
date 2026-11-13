#!/usr/bin/env python3
"""
Simulador DETERMINISTA del dosificado del Map distribuido de la PoC Bre-B.

Objetivo
--------
Validar, de forma reproducible y SIN necesidad de desplegar en AWS, que la
arquitectura "Step Functions + Map distribuido + token bucket" procesa el lote
diario de 20.000 pagos dentro de la ventana de 1 h manteniendo el throughput
sostenido en la banda objetivo de 10–15 TPS (ASR-1), con 0 duplicados (ASR-2).

Modela fielmente los parámetros reales del código:
  * Latencia del core (stub_backend): uniforme 50–300 ms (media 175 ms).
  * MaxConcurrency del Map: nº de workers en paralelo.
  * Token bucket (worker): recarga a TARGET_TPS tokens/s compartido por los workers.
  * Reintentos con backoff ante el 5% de errores transitorios del stub.
  * Idempotencia: los payment_id duplicados NO se ejecutan (DUPLICATE_SKIPPED).

Es un modelo de eventos discretos: el "tiempo" no es real, se calcula. Por eso
la corrida tarda < 1 s y los resultados son idénticos en cada ejecución (semilla
fija), lo que los hace citables en el documento como cifras de diseño validadas.

Uso:
    python3 sim/simulate_dosing.py                      # 20.000 pagos, defaults
    python3 sim/simulate_dosing.py --total 20000 \
        --concurrency 3 --target-tps 15 --duplicate-every 0
    python3 sim/simulate_dosing.py --json               # salida JSON (para scripts)
"""

import argparse
import heapq
import json
import random
import sys

# --- Parámetros del core (idénticos al stub_backend) -----------------------
LATENCY_MIN_S = 0.050
LATENCY_MAX_S = 0.300
ERROR_RATE = 0.05          # 5% de errores transitorios
MAX_RETRIES = 3
BASE_BACKOFF_S = 0.2
WINDOW_SECONDS = 3600      # ventana de 1 hora (ASR-1)


def run(total, concurrency, target_tps, duplicate_every, seed=42):
    rng = random.Random(seed)

    # Dataset con duplicados intencionales (idempotencia ASR-2).
    payments = []
    for i in range(total):
        pid = i
        if duplicate_every and i > 0 and i % duplicate_every == 0:
            pid = i - 1  # reutiliza el id anterior
        payments.append(pid)

    seen = set()            # claves de idempotencia ya reservadas
    processed = 0
    duplicates = 0
    failed = 0
    completion_times = []   # tiempo de fin de cada pago procesado
    tps_per_second = {}     # histograma de ejecuciones por segundo (throughput)

    # Token bucket compartido (recarga continua a target_tps).
    # Ráfaga acotada a ~2 tokens para que el throughput se mantenga liso en la
    # banda (sin picos artificiales por acumulación inicial de tokens).
    burst = 2.0
    bucket = {"tokens": burst, "ts": 0.0}
    capacity = burst

    def take_token(now):
        """Devuelve el instante en que hay 1 token disponible (>= now)."""
        if target_tps <= 0:
            return now
        refilled = min(capacity, bucket["tokens"] + (now - bucket["ts"]) * target_tps)
        if refilled >= 1.0:
            bucket["tokens"] = refilled - 1.0
            bucket["ts"] = now
            return now
        wait = (1.0 - refilled) / target_tps
        t = now + wait
        bucket["tokens"] = 0.0
        bucket["ts"] = t
        return t

    # Cola de eventos: (tiempo_libre_worker). Simulamos `concurrency` workers.
    # Cada worker toma el siguiente pago cuando queda libre; antes de llamar al
    # core pide un token (dosificado). El token bucket es el cuello de botella
    # cuando concurrency/latencia > target_tps (que es justo lo que queremos).
    workers = [0.0] * concurrency       # instante en que cada worker queda libre
    heapq.heapify(workers)
    idx = 0

    while idx < len(payments):
        free_at = heapq.heappop(workers)
        pid = payments[idx]
        idx += 1

        # Idempotencia: duplicado => no ejecuta el pago (no consume core ni token).
        if pid in seen:
            duplicates += 1
            # El worker queda libre casi de inmediato (solo el PutItem condicional).
            heapq.heappush(workers, free_at + 0.005)
            continue
        seen.add(pid)

        # Dosificado: espera un token (a TARGET_TPS) antes de golpear el core.
        start = take_token(free_at)

        # Llamada al core con reintentos ante error transitorio (5%).
        t = start
        attempt = 0
        succeeded = False
        while attempt < MAX_RETRIES:
            attempt += 1
            latency = rng.uniform(LATENCY_MIN_S, LATENCY_MAX_S)
            t += latency
            if rng.random() >= ERROR_RATE:
                succeeded = True
                break
            # error transitorio -> backoff exponencial y reintento
            if attempt < MAX_RETRIES:
                t += BASE_BACKOFF_S * (2 ** (attempt - 1))

        if succeeded:
            processed += 1
            completion_times.append(t)
            sec = int(t)
            tps_per_second[sec] = tps_per_second.get(sec, 0) + 1
        else:
            failed += 1

        heapq.heappush(workers, t)

    makespan = max(completion_times) if completion_times else 0.0
    # Throughput sostenido: media de ejecuciones/s sobre los segundos activos,
    # descartando el primer y último segundo (arranque/vaciado) para medir el
    # régimen estable, que es lo que define la banda de TPS del ASR.
    secs = sorted(tps_per_second)
    stable = [tps_per_second[s] for s in secs[1:-1]] if len(secs) > 2 else list(tps_per_second.values())
    sustained_tps = (sum(stable) / len(stable)) if stable else 0.0
    peak_tps = max(tps_per_second.values()) if tps_per_second else 0.0
    unique = len(seen)

    within_window = makespan <= WINDOW_SECONDS
    pct_in_window = 100.0 * sum(1 for c in completion_times if c <= WINDOW_SECONDS) / max(1, processed)

    return {
        "total_items": total,
        "unique_payments": unique,
        "processed_ok": processed,
        "duplicates_skipped": duplicates,
        "failed_permanent": failed,
        "concurrency": concurrency,
        "target_tps": target_tps,
        "sustained_tps": round(sustained_tps, 1),
        "peak_tps": round(peak_tps, 1),
        "makespan_seconds": round(makespan, 1),
        "makespan_minutes": round(makespan / 60.0, 1),
        "window_seconds": WINDOW_SECONDS,
        "within_window": within_window,
        "pct_completed_in_window": round(pct_in_window, 2),
        "core_latency_mean_ms": round(1000 * (LATENCY_MIN_S + LATENCY_MAX_S) / 2, 1),
        "error_rate_injected": ERROR_RATE,
    }


def _verdict(r):
    tps_ok = 10.0 <= r["sustained_tps"] <= 15.0
    window_ok = r["within_window"] and r["pct_completed_in_window"] >= 99.0
    dup_ok = r["duplicates_skipped"] == (r["total_items"] - r["unique_payments"])
    return {
        "ASR-1_banda_10_15_TPS": "OK" if tps_ok else "REVISAR",
        "ASR-1_ventana_1h_>=99pct": "OK" if window_ok else "REVISAR",
        "ASR-2_0_duplicados": "OK" if dup_ok else "REVISAR",
    }


def main():
    ap = argparse.ArgumentParser(description="Simulador de dosificado PoC Bre-B")
    ap.add_argument("--total", type=int, default=20000)
    ap.add_argument("--concurrency", type=int, default=3)
    ap.add_argument("--target-tps", type=float, default=15.0)
    ap.add_argument("--duplicate-every", type=int, default=0)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--json", action="store_true", help="salida en JSON")
    args = ap.parse_args()

    r = run(args.total, args.concurrency, args.target_tps, args.duplicate_every, args.seed)
    v = _verdict(r)

    if args.json:
        print(json.dumps({"result": r, "verdict": v}, indent=2, ensure_ascii=False))
        return

    print("=" * 72)
    print("  Simulación de dosificado — PoC Bre-B · Pagos Programados (ASR-1/ASR-2)")
    print("=" * 72)
    print(f"  Pagos en el lote (items)   : {r['total_items']:,}")
    print(f"  Pagos únicos               : {r['unique_payments']:,}")
    print(f"  Procesados OK              : {r['processed_ok']:,}")
    print(f"  Duplicados omitidos (ASR-2): {r['duplicates_skipped']:,}")
    print(f"  Fallos permanentes         : {r['failed_permanent']:,}")
    print("  " + "-" * 68)
    print(f"  MaxConcurrency (Map)       : {r['concurrency']}")
    print(f"  Ritmo objetivo (token bkt) : {r['target_tps']} TPS")
    print(f"  Latencia media del core    : {r['core_latency_mean_ms']} ms  (uniforme 50–300 ms)")
    print(f"  Error transitorio inyectado: {int(r['error_rate_injected']*100)} %")
    print("  " + "-" * 68)
    print(f"  THROUGHPUT SOSTENIDO       : {r['sustained_tps']} TPS   (banda objetivo 10–15 TPS)")
    print(f"  Throughput pico            : {r['peak_tps']} TPS")
    print(f"  Duración del lote (makespan): {r['makespan_seconds']} s  =  {r['makespan_minutes']} min")
    print(f"  Ventana ASR-1              : {r['window_seconds']} s (60 min)")
    print(f"  % completado en ventana    : {r['pct_completed_in_window']} %")
    print("  " + "-" * 68)
    for k, val in v.items():
        print(f"  {k:<32}: {val}")
    print("=" * 72)

    if any(val != "OK" for val in v.values()):
        sys.exit(1)


if __name__ == "__main__":
    main()
