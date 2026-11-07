'use strict';

const assert = require('node:assert/strict');
const { execFileSync, spawnSync } = require('node:child_process');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const cli = path.resolve(__dirname, '..', 'src', 'cli.cjs');

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'tapo-cli-test-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const privateDir = path.join(root, 'private');
  await fs.mkdir(privateDir, { mode: 0o700 });
  const env = {
    ...process.env, CREDENTIALS_DIRECTORY: '',
    TAPO_CONFIG: path.join(privateDir, 'config.json'),
    TAPO_TOKEN_FILE: path.join(privateDir, 'camera-tokens.json'),
  };
  const config = {
    cameras: [{ id: 'front', host: '10.42.0.21', name: 'Front door' }],
    recordingsDir: path.join(root, 'recordings'),
    statusFile: path.join(privateDir, 'status.json'),
  };
  await fs.writeFile(env.TAPO_CONFIG, JSON.stringify(config));
  return { privateDir, env, config };
}

test('status shows health without opening the token file', async (t) => {
  const { env, config } = await fixture(t);
  await fs.writeFile(config.statusFile, JSON.stringify({
    state: 'running', updatedAt: new Date().toISOString(),
    cameras: [{ id: 'front', lastReplyAt: null }],
  }));
  const result = JSON.parse(execFileSync(process.execPath, [cli, '--status'], { env, encoding: 'utf8' }));
  assert.equal(result.state, 'running');
  assert.equal(result.stale, false);
  assert.equal(result.cameras[0].replyStale, true);
});

test('blocks a recordings path that exposes private files through a symlink', async (t) => {
  const { privateDir, env, config } = await fixture(t);
  await fs.symlink(privateDir, config.recordingsDir);
  const result = spawnSync(process.execPath, [cli, '--status'], { env, encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /dedicated recordings folder/);
});

test('ordinary credential files must remain readable only by their owner', async (t) => {
  const { env } = await fixture(t);
  await fs.writeFile(env.TAPO_TOKEN_FILE, JSON.stringify({
    type: 'tapo-lat/v1',
    cameras: { camerafront: { host: '10.42.0.21', lat: 'fixture' } },
  }));
  await fs.chmod(env.TAPO_TOKEN_FILE, 0o640);
  const result = spawnSync(process.execPath, [cli, '--check'], { env, encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Credential permissions are too broad/);
  assert.doesNotMatch(result.stderr, /"lat"/);
});
