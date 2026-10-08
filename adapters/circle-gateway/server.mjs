import { AsyncLocalStorage } from 'node:async_hooks';

import { createGatewayMiddleware } from '@circle-fin/x402-batching/server';
import express from 'express';

const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const USDC_PRICE = /^([0-9]+)(?:\.([0-9]{1,6}))?$/;
const ARC_MAINNET = 'eip155:5042';

function readConfiguration(env) {
  const sellerAddress = env.SELLER_ADDRESS ?? '';
  const decisionUrl = new URL(env.UPSTREAM_DECISION_URL ?? '');
  const bearerToken = env.UPSTREAM_BEARER_TOKEN ?? '';
  const price = env.PRICE_USDC ?? '0.06';

  if (!ADDRESS.test(sellerAddress) || /^0x0{40}$/i.test(sellerAddress)) {
    throw new Error('SELLER_ADDRESS must be a non-zero EVM address');
  }
  if (!['http:', 'https:'].includes(decisionUrl.protocol)
      || decisionUrl.username || decisionUrl.password) {
    throw new Error('UPSTREAM_DECISION_URL must be a credential-free HTTP(S) URL');
  }
  if (bearerToken.length < 32 || bearerToken.length > 256 || /[\r\n]/.test(bearerToken)) {
    throw new Error('UPSTREAM_BEARER_TOKEN must contain 32-256 safe characters');
  }
  const priceMatch = USDC_PRICE.exec(price);
  if (!priceMatch) throw new Error('PRICE_USDC must be a positive USDC decimal');
  const atomicAmount = BigInt(priceMatch[1]) * 1_000_000n
    + BigInt((priceMatch[2] ?? '').padEnd(6, '0'));
  if (atomicAmount <= 0n) throw new Error('PRICE_USDC must be positive');

  const facilitatorUrl = env.GATEWAY_FACILITATOR_URL?.trim();
  if (facilitatorUrl) {
    const facilitator = new URL(facilitatorUrl);
    if (facilitator.protocol !== 'https:' || facilitator.username || facilitator.password) {
      throw new Error('GATEWAY_FACILITATOR_URL must be a credential-free HTTPS origin');
    }
  }
  return {
    sellerAddress, decisionUrl, bearerToken, price,
    atomicAmount: atomicAmount.toString(), facilitatorUrl,
  };
}

async function prepareDecision(config, body, fetchImpl) {
  const response = await fetchImpl(config.decisionUrl, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${config.bearerToken}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(58_000),
  });
  const text = await response.text();
  if (text.length > 2_000_000) throw new Error('upstream_response_too_large');
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    throw new Error('upstream_response_invalid');
  }
  if (!response.ok || !value || typeof value !== 'object' || !value.decision) {
    throw new Error(`upstream_decision_unavailable:${response.status}`);
  }
  return value;
}

export function createSellerAdapter({
  env = process.env,
  gatewayFactory = createGatewayMiddleware,
  fetchImpl = fetch,
  resolveDecision,
} = {}) {
  const config = readConfiguration(env);
  const requestState = new AsyncLocalStorage();
  const app = express();
  const gateway = gatewayFactory({
    sellerAddress: config.sellerAddress,
    networks: [ARC_MAINNET],
    ...(config.facilitatorUrl ? { facilitatorUrl: config.facilitatorUrl } : {}),
  });
  const prepare = resolveDecision ?? ((body) => prepareDecision(config, body, fetchImpl));

  gateway.onBeforeSettle(async () => {
    const state = requestState.getStore();
    if (!state) return { abort: true, reason: 'missing_request_context' };
    try {
      state.result = await prepare(state.body);
    } catch {
      return {
        abort: true,
        reason: 'decision_preparation_failed',
        message: 'A checked decision could not be prepared, so payment was not settled.',
      };
    }
  });

  const paymentGate = gateway.require(`$${config.price}`);
  app.disable('x-powered-by');
  app.get('/livez', (_req, res) => res.json({ status: 'ok' }));
  app.post(
    '/v2/resolve',
    express.json({ limit: '64kb', strict: true }),
    (req, res, next) => requestState.run(
      { body: req.body, result: null },
      () => paymentGate(req, res, next),
    ),
    (req, res) => {
      const state = requestState.getStore();
      if (!state?.result || !req.payment?.verified
          || req.payment.amount !== config.atomicAmount
          || req.payment.network !== ARC_MAINNET) {
        res.status(502).json({ detail: 'gateway_payment_state_invalid' });
        return;
      }
      res.setHeader('cache-control', 'no-store');
      res.json({
        ...state.result,
        payment_receipt: {
          success: true,
          protocol: 'x402',
          rail: 'circle_gateway',
          currency: 'USDC',
          amount: req.payment.amount,
          network: req.payment.network,
          payer: req.payment.payer,
          ...(req.payment.transaction ? { transaction: req.payment.transaction } : {}),
        },
      });
    },
  );
  app.use((_req, res) => res.status(404).json({ detail: 'not_found' }));
  app.use((error, _req, res, _next) => {
    if (res.headersSent) return res.end();
    const status = error?.type === 'entity.too.large'
      ? 413
      : error?.type === 'entity.parse.failed' || error instanceof SyntaxError
        ? 400
        : 502;
    const detail = status === 413
      ? 'body_too_large'
      : status === 400 ? 'invalid_json' : 'upstream_unavailable';
    res.status(status).json({ detail });
  });
  return app;
}
