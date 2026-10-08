import assert from 'node:assert/strict';
import { once } from 'node:events';
import test from 'node:test';

import { createSellerAdapter } from './server.mjs';

const env = {
  SELLER_ADDRESS: '0x1111111111111111111111111111111111111111',
  UPSTREAM_DECISION_URL: 'https://api.example.com/internal/gateway/resolve',
  UPSTREAM_BEARER_TOKEN: 'test-token-'.repeat(4),
  PRICE_USDC: '0.06',
};

function fakeGatewayFactory(config) {
  assert.deepEqual(config.networks, ['eip155:5042']);
  let beforeSettle;
  return {
    onBeforeSettle(hook) { beforeSettle = hook; return this; },
    require(price) {
      assert.equal(price, '$0.06');
      return async (req, res, next) => {
        if (!req.get('payment-signature')) {
          const challenge = {
            x402Version: 2,
            accepts: [
              { scheme: 'exact', network: 'eip155:5042', amount: '60000' },
            ],
          };
          res.setHeader('payment-required', Buffer.from(JSON.stringify(challenge)).toString('base64'));
          res.status(402).json(challenge);
          return;
        }
        const directive = await beforeSettle({});
        if (directive?.abort) {
          res.status(402).json({ reason: directive.reason });
          return;
        }
        req.payment = {
          verified: true,
          payer: '0x2222222222222222222222222222222222222222',
          amount: '60000',
          network: 'eip155:5042',
          transaction: `0x${'33'.repeat(32)}`,
        };
        res.setHeader('payment-response', 'test-receipt');
        next();
      };
    },
  };
}

async function running(app, action) {
  const server = app.listen(0, '127.0.0.1');
  await once(server, 'listening');
  try {
    return await action(`http://127.0.0.1:${server.address().port}`);
  } finally {
    server.close();
    await once(server, 'close');
  }
}

test('unpaid request returns an Arc Mainnet x402 challenge', async () => {
  let prepared = 0;
  const app = createSellerAdapter({
    env,
    gatewayFactory: fakeGatewayFactory,
    resolveDecision: async () => { prepared += 1; },
  });
  await running(app, async (origin) => {
    const response = await fetch(`${origin}/v2/resolve`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}',
    });
    assert.equal(response.status, 402);
    assert.ok(response.headers.get('payment-required'));
    assert.deepEqual(
      (await response.json()).accepts.map((entry) => entry.network),
      ['eip155:5042'],
    );
    assert.equal(prepared, 0);
  });
});

test('checked result is prepared before settlement', async () => {
  const app = createSellerAdapter({
    env,
    gatewayFactory: fakeGatewayFactory,
    resolveDecision: async (body) => ({ decision: { action_id: body.action } }),
  });
  await running(app, async (origin) => {
    const response = await fetch(`${origin}/v2/resolve`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'payment-signature': 'paid' },
      body: JSON.stringify({ action: 'check_status' }),
    });
    const body = await response.json();
    assert.equal(response.status, 200);
    assert.equal(body.decision.action_id, 'check_status');
    assert.equal(body.payment_receipt.amount, '60000');
    assert.equal(response.headers.get('payment-response'), 'test-receipt');
  });
});

test('failed preparation aborts settlement without leaking the cause', async () => {
  const app = createSellerAdapter({
    env,
    gatewayFactory: fakeGatewayFactory,
    resolveDecision: async () => { throw new Error('private provider error'); },
  });
  await running(app, async (origin) => {
    const response = await fetch(`${origin}/v2/resolve`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'payment-signature': 'paid' },
      body: '{}',
    });
    assert.equal(response.status, 402);
    assert.deepEqual(await response.json(), { reason: 'decision_preparation_failed' });
  });
});
