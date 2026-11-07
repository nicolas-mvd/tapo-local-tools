'use strict';

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { createInterface } = require('node:readline');
const test = require('node:test');

const resources = process.env.TAPO_MAC_RESOURCES || path.resolve(__dirname, '..');

test('Mac bridge supports legacy and named cameras without leaking tokens', { timeout: 15_000 }, async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'tapo-bridge-test-'));
  const config = path.join(directory, 'config.json');
  const tokens = path.join(directory, 'camera-tokens.json');
  const probe = path.join(directory, 'probe');
  const auth = 'test-session-' + 'a'.repeat(32);
  let child;
  let closed;

  async function configure(cameras) {
    await fs.writeFile(config, JSON.stringify({ cameras }), { mode: 0o600 });
  }

  try {
    await fs.writeFile(probe, `#!/usr/bin/env node
const fs = require('node:fs');
const { cameras } = JSON.parse(fs.readFileSync(process.argv[4], 'utf8'));
if (cameras.some(({ id }) => id === 'probe-error')) process.exit(1);
process.stdout.write(JSON.stringify(cameras.map(({ id, host }) => ({
  id, host, batteryPercent: 16, charging: false, online: true,
}))));
`, { mode: 0o700 });
    child = spawn(process.execPath, [path.join(resources, 'macos', 'bridge.cjs')], {
      env: {
        ...process.env, TAPO_CONFIG: config, TAPO_TOKEN_FILE: tokens, TAPO_PYTHON: probe,
        TAPO_BRIDGE_TOKEN: auth,
      },
      stdio: ['ignore', 'pipe', 'inherit'],
    });
    closed = once(child, 'close');
    const output = createInterface({ input: child.stdout });
    const port = await Promise.race([
      once(output, 'line').then(([line]) => JSON.parse(line).port),
      closed.then(([code]) => { throw new Error(`Bridge did not start (${code})`); }),
    ]);
    const get = (endpoint, token = auth) => fetch(`http://127.0.0.1:${port}${endpoint}`, {
      headers: { authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(5_000),
    });

    assert.equal((await get('/status', 'wrong')).status, 401);
    assert.deepEqual(await (await get('/status')).json(), { cameras: [], probeFailed: false });
    assert.equal((await get('/live/1')).status, 409);

    const one = { id: '1', host: '192.168.50.20' };
    await configure([one]);
    await fs.writeFile(tokens, JSON.stringify({
      type: 'tapo-lat/v1',
      cameras: { camera1: { host: one.host, lat: 'fixture-token' } },
    }), { mode: 0o600 });
    const status = await (await get('/status')).json();
    assert.equal(status.cameras.length, 1);
    const [camera] = status.cameras;
    assert.deepEqual(camera, {
      ...one, batteryPercent: 16, charging: false, online: true, hasCredentials: true,
      checkedAt: camera.checkedAt,
    });
    assert.ok(Math.abs(Date.now() / 1000 - camera.checkedAt) < 5);

    const multiple = Array.from({ length: 16 }, (_, index) => ({
      id: `cam-${index}`, host: `10.1.1.${index + 1}`, name: `Camera ${index + 1}`,
    }));
    multiple[0] = one;
    await configure(multiple);
    const named = await (await get('/status')).json();
    assert.equal(named.cameras.length, 16);
    assert.equal(named.cameras[0].hasCredentials, true);
    assert.equal(named.cameras[1].id, 'cam-1');
    assert.equal(named.cameras[1].hasCredentials, false);
    assert.equal((await get('/live/cam-1')).status, 403);
    assert.equal((await get('/live/no-such-camera')).status, 404);

    await configure([{ ...one, id: 'probe-error' }]);
    const failed = await (await get('/status')).json();
    assert.equal(failed.probeFailed, true);
    assert.equal(failed.cameras[0].online, false);
    assert.equal(failed.cameras[0].checkedAt, undefined);

    await configure([one, one]);
    assert.equal((await get('/status')).status, 500);
  } finally {
    child?.kill('SIGTERM');
    await closed;
    await fs.rm(directory, { recursive: true, force: true });
  }
});
