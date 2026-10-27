// Escenario ESTRÉS (pico) — 6.000 mensajes (3x el volumen normal).
// Criterio de éxito: degradación controlada; 0 mensajes perdidos; backlog
// drenado sin superar la ventana. La concurrencia reservada (N=20) debe
// mantener protegido al backend aunque el backlog crezca.
//
// Ejecutar:
//   export AWS_REGION=us-east-1
//   export QUEUE_URL=$(cd ../terraform && terraform output -raw queue_url)
//   k6 run stress.js
import { buildClient, queueUrl, buildPayment } from './lib/producer.js';

const TOTAL = Number(__ENV.TOTAL || 6000);

export const options = {
  scenarios: {
    spike: {
      executor: 'shared-iterations',
      vus: 50,          // inyección agresiva para formar el pico
      iterations: TOTAL,
      maxDuration: '10m',
    },
  },
};

const sqs = buildClient();
const url = queueUrl();

export default function () {
  const idx = __ITER;
  const body = buildPayment(idx, 'stress', 0);
  sqs.sendMessage(url, body);
}
