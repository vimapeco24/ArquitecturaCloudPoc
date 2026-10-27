// Escenario NORMAL — 2.000 mensajes en la ventana.
// Criterio de éxito: >=99% procesados; p95 <= 2s; error rate < 1%.
//
// Ejecutar:
//   export AWS_REGION=us-east-1
//   export QUEUE_URL=$(cd ../terraform && terraform output -raw queue_url)
//   k6 run normal.js
import { buildClient, queueUrl, buildPayment } from './lib/producer.js';

const TOTAL = Number(__ENV.TOTAL || 2000);

// Reparte TOTAL envíos a lo largo de la ejecución con una tasa constante.
export const options = {
  scenarios: {
    inject: {
      executor: 'shared-iterations',
      vus: 20,
      iterations: TOTAL,
      maxDuration: '10m',
    },
  },
  thresholds: {
    // El envío a SQS debe ser rápido; el procesamiento se mide en CloudWatch.
    iteration_duration: ['p95<2000'],
  },
};

const sqs = buildClient();
const url = queueUrl();

export default function () {
  const idx = __ITER;
  const body = buildPayment(idx, 'normal', 0);
  sqs.sendMessage(url, body);
}
