import { createSellerAdapter } from './server.mjs';

const port = Number.parseInt(process.env.PORT ?? '3000', 10);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error('PORT must be an integer from 1 to 65535');
}
const host = process.env.HOST?.trim() || '127.0.0.1';
if (/[\r\n\0]/.test(host)) throw new Error('HOST contains invalid characters');

createSellerAdapter().listen(port, host, () => {
  process.stdout.write(`Circle Gateway seller adapter listening on ${host}:${port}\n`);
});
