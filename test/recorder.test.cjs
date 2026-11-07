'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { EventEmitter } = require('node:events');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');
const { setTimeout: delay } = require('node:timers/promises');
const { startMotionRecorder } = require('../src/record.cjs');

const ffmpeg = process.env.TAPO_TEST_FFMPEG || 'ffmpeg';
const ffmpegMissing = !process.env.TAPO_TEST_FFMPEG
  && spawnSync(ffmpeg, ['-version']).error?.code === 'ENOENT';

function videoFixture() {
  const result = spawnSync(ffmpeg, [
    '-nostdin', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=red:s=96x64:r=10',
    '-t', '1', '-an', '-c:v', 'mpeg2video', '-threads', '1', '-f', 'mpegts', 'pipe:1',
  ]);
  assert.equal(result.status, 0, result.stderr?.toString() || result.error?.message);
  return result.stdout;
}

function preview(bytes) {
  const live = new EventEmitter();
  live.info = { videoCodec: 'h264' };
  live.getStartupPackets = () => bytes;
  live.ended = true;
  live.close = () => {};
  return live;
}

async function waitFor(filename) {
  for (let attempt = 0; attempt < 200; attempt++) {
    if (fs.existsSync(filename)) return;
    await delay(20);
  }
  throw new Error(`Timed out waiting for ${path.basename(filename)}`);
}

test('coalesces newer alarms while busy, retries a wake failure and publishes a playable clip', {
  skip: ffmpegMissing && 'FFmpeg is required for the synthetic video fixture',
  timeout: 20_000,
}, async (t) => {
  const directory = await fsp.mkdtemp(path.join(os.tmpdir(), 'tapo-recorder-test-'));
  t.after(() => fsp.rm(directory, { recursive: true, force: true }));
  const outputDir = path.join(directory, 'clips');
  const statusFile = path.join(directory, 'status.json');
  const watchPath = path.join(directory, 'watch.py');
  const firstOpen = path.join(directory, 'first-open');
  const pendingSent = path.join(directory, 'pending-sent');
  const clipSaved = path.join(directory, 'clip-saved');
  const camera = { id: '1', name: 'Fixture', host: '192.168.50.20' };
  const bytes = videoFixture();
  await fsp.writeFile(watchPath, `
import json
from pathlib import Path
import time

def wait_for(name):
    for _ in range(400):
        if Path(name).exists():
            return
        time.sleep(0.02)
    raise SystemExit(2)

def event(**fields):
    print(json.dumps(fields), flush=True)

event(type="ready")
event(type="reply", host="${camera.host}", alarm=0, motion=False)
event(type="reply", host="${camera.host}", alarm=100, motion=True)
wait_for(${JSON.stringify(firstOpen)})
for alarm in (101, 102, 102):
    event(type="reply", host="${camera.host}", alarm=alarm, motion=True)
Path(${JSON.stringify(pendingSent)}).touch()
wait_for(${JSON.stringify(clipSaved)})
`);
  const logs = [];
  let openings = 0;
  let ready = false;
  const options = {
    cameras: [camera], ffmpeg, watchPath, outputDir, statusFile,
    onReady: async () => { ready = true; },
    report: (message) => {
      logs.push(message);
      if (message.startsWith('Camera 1: saved ')) fs.writeFileSync(clipSaved, '');
    },
    openPreview: async () => {
      assert.equal(ready, true);
      openings++;
      if (openings === 1) {
        await fsp.writeFile(firstOpen, '');
        await waitFor(pendingSent);
        await delay(40);
        throw new Error('Synthetic disconnect while busy');
      }
      if (openings === 2) throw new Error('Synthetic delayed wake');
      return preview(bytes);
    },
  };

  await assert.rejects(startMotionRecorder(options), /Motion watcher exited unexpectedly \(0\)/);
  assert.equal(openings, 3);
  assert.equal(logs.filter((message) => message === 'Camera 1: retrying motion capture.').length, 1);
  const filename = 'camera-1_1970-01-01T00-01-42-000Z.mp4';
  assert.deepEqual((await fsp.readdir(outputDir)).filter((file) => file.endsWith('.mp4')), [filename]);
  const result = spawnSync(ffmpeg, [
    '-nostdin', '-loglevel', 'error', '-xerror', '-i', path.join(outputDir, filename), '-f', 'null', '-',
  ]);
  assert.equal(result.status, 0, result.stderr?.toString());
  const status = JSON.parse(await fsp.readFile(statusFile, 'utf8'));
  assert.equal(status.state, 'failed');
  assert.equal(status.cameras[0].lastClip, filename);
  assert.equal(status.cameras[0].lastAlarmAt, '1970-01-01T00:01:42.000Z');
  assert.match(status.cameras[0].lastReplyAt, /^\d{4}-\d{2}-\d{2}T/);
  assert.match(status.cameras[0].lastError, /Could not open the camera stream/);
  assert.equal((await fsp.stat(statusFile)).mode & 0o777, 0o600);
});
