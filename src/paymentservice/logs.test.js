// No card data in the logs (ADR 0011): neither the card number (or its last digits), the CVV nor
// the expiry. pino writes to fd 1 directly, so the handler runs in a child process and the test
// reads its stdout.
'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const { spawnSync } = require('node:child_process');

const CARD = '4432-8015-6152-0454';
const CHILD = `
  const Server = require('./server');
  const year = new Date().getFullYear();
  const card = (y) => ({ credit_card_number: ${JSON.stringify(CARD)}, credit_card_cvv: 672,
                         credit_card_expiration_year: y, credit_card_expiration_month: 1 });
  const amount = { currency_code: 'USD', units: 10, nanos: 0 };
  for (const y of [year + 1, year - 1]) {               // charged, then expired
    Server.ChargeServiceHandler({ request: { amount, credit_card: card(y) } }, (err, res) => {
      console.error(err ? 'ERR ' + err.message : 'OK ' + res.transaction_id);
    });
  }
`;

test('the charge logs hold no card data', () => {
  const out = spawnSync(process.execPath, ['-e', CHILD], { cwd: __dirname, encoding: 'utf8', timeout: 20000 });
  assert.strictEqual(out.status, 0, out.stderr);
  assert.match(out.stderr, /^OK /m);
  assert.match(out.stderr, /^ERR Your credit card has expired$/m); // the error message too
  assert.match(out.stdout, /Transaction processed/);
  // Every log line without its time and pid (numbers that could contain the digits by chance)
  const logs = out.stdout.trim().split('\n').map((line) => {
    const { time, pid, ...rest } = JSON.parse(line);
    return JSON.stringify(rest);
  }).join('\n') + out.stderr;
  for (const secret of [CARD, CARD.replace(/-/g, ''), '0454', '672', 'credit_card']) {
    assert.ok(!logs.includes(secret), `logs contain ${secret}:\n${logs}`);
  }
});
