// Helper compartido para inyectar mensajes en SQS desde k6 usando SigV4.
// Usa la jslib oficial de k6 para AWS (SQS + SignatureV4 vía credenciales de entorno).
import { AWSConfig, SQSClient } from 'https://jslib.k6.io/aws/0.12.3/sqs.js';

// Credenciales tomadas del entorno (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
// AWS_SESSION_TOKEN opcional) y región (AWS_REGION).
export function buildClient() {
  const awsConfig = new AWSConfig({
    region: __ENV.AWS_REGION || 'us-east-1',
    accessKeyID: __ENV.AWS_ACCESS_KEY_ID,
    secretAccessKey: __ENV.AWS_SECRET_ACCESS_KEY,
    sessionToken: __ENV.AWS_SESSION_TOKEN, // undefined si no aplica
  });
  return new SQSClient(awsConfig);
}

export function queueUrl() {
  const url = __ENV.QUEUE_URL;
  if (!url) {
    throw new Error('Define QUEUE_URL (terraform output -raw queue_url)');
  }
  return url;
}

// Genera el cuerpo de un mensaje de pago programado con payment_id único
// (clave de idempotencia). Incluye un pequeño % de duplicados deliberados
// para demostrar que el consumidor NO ejecuta pagos repetidos (ASR-2).
export function buildPayment(index, iteration, duplicateEvery) {
  // Cada 'duplicateEvery' mensajes reutilizamos un payment_id previo.
  let paymentId;
  if (duplicateEvery > 0 && index % duplicateEvery === 0 && index > 0) {
    paymentId = `pay-${iteration}-${index - 1}`; // duplicado intencional
  } else {
    paymentId = `pay-${iteration}-${index}`;
  }
  return JSON.stringify({
    payment_id: paymentId,
    account_from: '000123456789',
    account_to: '000987654321',
    key_breb: `@llave${index}`,
    amount: 50000 + (index % 100) * 1000,
    currency: 'COP',
    scheduled_for: '2026-01-01T06:00:00-05:00',
    periodicity: 'ONCE',
  });
}
