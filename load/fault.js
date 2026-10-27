// Escenario FALLO TRANSITORIO — valida reintentos/backoff, DLQ y 0 duplicados.
//
// Prerrequisito: despliega el stub con error inyectado:
//   stub_error_rate = 0.05  en terraform.tfvars  (5% de errores)
//
// Además, este escenario inyecta DUPLICADOS intencionales (mismo payment_id)
// cada 'DUP_EVERY' mensajes para demostrar que el consumidor NO ejecuta el
// pago dos veces (idempotencia en DynamoDB → ASR-2: 0 duplicados).
//
// Criterio de éxito: reintentos con backoff; mensajes no procesables en DLQ;
// 0 pagos duplicados verificados en DynamoDB.
//
// Ejecutar:
//   export AWS_REGION=us-east-1
//   export QUEUE_URL=$(cd ../terraform && terraform output -raw queue_url)
//   k6 run fault.js
import { buildClient, queueUrl, buildPayment } from './lib/producer.js';

const TOTAL = Number(__ENV.TOTAL || 2000);
const DUP_EVERY = Number(__ENV.DUP_EVERY || 25); // 1 de cada 25 es duplicado

export const options = {
  scenarios: {
    fault: {
      executor: 'shared-iterations',
      vus: 20,
      iterations: TOTAL,
      maxDuration: '10m',
    },
  },
};

const sqs = buildClient();
const url = queueUrl();

export default function () {
  const idx = __ITER;
  const body = buildPayment(idx, 'fault', DUP_EVERY);
  sqs.sendMessage(url, body);
}
