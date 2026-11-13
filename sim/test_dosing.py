#!/usr/bin/env python3
"""
Pruebas del simulador de dosificado y de la lógica de banda 10–15 TPS (ASR-1/ASR-2).

Ejecutar:  python3 sim/test_dosing.py   (sin dependencias externas: usa unittest)
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from simulate_dosing import run, WINDOW_SECONDS  # noqa: E402


class TestDosing(unittest.TestCase):
    def test_20k_15tps_en_banda_y_ventana(self):
        """20.000 pagos a 15 TPS: throughput en banda y lote dentro de 1 h."""
        r = run(total=20000, concurrency=3, target_tps=15, duplicate_every=0)
        self.assertEqual(r["unique_payments"], 20000)
        self.assertTrue(10.0 <= r["sustained_tps"] <= 15.0,
                        f"TPS fuera de banda: {r['sustained_tps']}")
        self.assertTrue(r["within_window"], "el lote no cabe en la ventana de 1 h")
        self.assertLessEqual(r["makespan_seconds"], WINDOW_SECONDS)
        self.assertGreaterEqual(r["pct_completed_in_window"], 99.0)

    def test_20k_10tps_en_banda(self):
        """Borde inferior de la banda: 10 TPS con concurrencia suficiente."""
        r = run(total=20000, concurrency=3, target_tps=10, duplicate_every=0)
        self.assertTrue(10.0 <= r["sustained_tps"] <= 15.0,
                        f"TPS fuera de banda: {r['sustained_tps']}")
        self.assertTrue(r["within_window"])

    def test_idempotencia_sin_duplicados(self):
        """ASR-2: los payment_id repetidos no se ejecutan dos veces."""
        r = run(total=20000, concurrency=3, target_tps=15, duplicate_every=50)
        # 1 de cada 50 (a partir del índice 50) reutiliza el id previo.
        esperados = r["total_items"] - r["unique_payments"]
        self.assertEqual(r["duplicates_skipped"], esperados)
        self.assertGreater(r["duplicates_skipped"], 0)
        # Nunca se procesa más de lo único.
        self.assertLessEqual(r["processed_ok"], r["unique_payments"])

    def test_dosificado_protege_el_core(self):
        """El throughput sostenido no excede el ritmo objetivo (protección del core)."""
        for tps in (10, 12, 15):
            r = run(total=5000, concurrency=5, target_tps=tps, duplicate_every=0)
            # Con concurrencia alta, el token bucket es el límite: TPS ≈ objetivo.
            self.assertLessEqual(r["sustained_tps"], tps + 1.0,
                                 f"a objetivo {tps} TPS el sostenido fue {r['sustained_tps']}")

    def test_determinista(self):
        """Misma semilla => mismo resultado (cifras citables en el documento)."""
        a = run(total=8000, concurrency=3, target_tps=15, duplicate_every=0, seed=42)
        b = run(total=8000, concurrency=3, target_tps=15, duplicate_every=0, seed=42)
        self.assertEqual(a, b)


if __name__ == "__main__":
    unittest.main(verbosity=2)
