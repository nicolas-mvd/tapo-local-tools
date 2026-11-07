'use strict';

const assert = require('node:assert/strict');
const { execFileSync, spawnSync } = require('node:child_process');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { openArchive } = require('../src/archive.cjs');

const dayMs = 86_400_000;

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'tapo-archive-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const outputDir = path.join(root, 'Motion clips');
  await fs.mkdir(outputDir, { mode: 0o700 });
  const reports = [];
  const options = {
    outputDir,
    cameras: [{ id: 'front', name: '<Front> & "door"' }],
    ffmpeg: path.join(root, 'unavailable-ffmpeg'),
    report: (message) => reports.push(message),
  };
  return { root, outputDir, options, reports };
}

function filename(id, time) {
  return 'camera-' + id + '_' + new Date(time).toISOString().replace(/[:.]/g, '-') + '.mp4';
}

test('timeline lists only finalized recorder clips, safely escapes names, and preserves files by default', async (t) => {
  const { root, outputDir, options } = await fixture(t);
  const clip = filename('front', Date.now() - 12 * dayMs);
  const removedCameraClip = filename('old-camera', Date.now());
  const symlinkClip = filename('linked', Date.now());
  const unrelated = [
    'unrelated.mp4',
    'camera-front_2026-02-30T00-00-00-000Z.mp4',
    'camera-front_2026-10-30T00-00-00-000Z.mp4.partial',
  ];
  await Promise.all([clip, removedCameraClip, ...unrelated].map((name) =>
    fs.writeFile(path.join(outputDir, name), 'fixture')));
  const outside = path.join(root, 'outside.mp4');
  await fs.writeFile(outside, 'outside');
  await fs.symlink(outside, path.join(outputDir, symlinkClip));

  const archive = await openArchive(options);
  const staging = await fs.stat(archive.incomingDir);
  assert.equal(staging.mode & 0o777, 0o700);
  assert.equal(staging.dev, (await fs.stat(outputDir)).dev);
  assert.equal(path.dirname(archive.incomingDir), await fs.realpath(root));
  const html = await fs.readFile(path.join(outputDir, 'index.html'), 'utf8');
  assert.match(html, /&lt;Front&gt; &amp; &quot;door&quot;/);
  assert.ok(html.includes(clip));
  assert.ok(html.includes(removedCameraClip));
  assert.ok(html.includes('Cam old-camera'));
  for (const name of [...unrelated, symlinkClip]) assert.ok(!html.includes(name));
  assert.equal(await fs.readFile(path.join(outputDir, clip), 'utf8'), 'fixture');
});

test('opt-in age and storage caps remove oldest finalized clips and their thumbnails only', async (t) => {
  const { root, outputDir, options } = await fixture(t);
  const now = Date.now();
  const expired = filename('front', now - 4 * dayMs);
  const older = filename('front', now - 60_000);
  const newest = filename('front', now);
  const link = filename('front', now - 7 * dayMs);
  const outside = path.join(root, 'outside.mp4');
  await fs.writeFile(outside, 'keep me');
  await fs.symlink(outside, path.join(outputDir, link));
  await Promise.all([expired, older, newest, 'other.mp4'].map((name) =>
    fs.writeFile(path.join(outputDir, name), '12345')));

  // Start without limits so the test can populate an owned thumbnail directory.
  await openArchive(options);
  const thumbs = path.join(outputDir, '.tapo-thumbnails');
  const expiredThumb = path.join(thumbs, expired.replace(/\.mp4$/, '.jpg'));
  await fs.writeFile(expiredThumb, 'fixture');
  await fs.writeFile(path.join(thumbs, 'other.jpg'), 'keep me');

  const archive = await openArchive({ ...options, retentionDays: 2, maxStorageBytes: 5 });
  assert.equal(await fs.readFile(path.join(outputDir, expired), 'utf8'), '12345');
  assert.equal(await fs.readFile(expiredThumb, 'utf8'), 'fixture');
  await Promise.all([archive.refresh(), archive.refresh()]);
  for (const file of [path.join(outputDir, expired), path.join(outputDir, older), expiredThumb]) {
    await assert.rejects(fs.lstat(file), { code: 'ENOENT' });
  }
  assert.ok((await fs.lstat(path.join(outputDir, link))).isSymbolicLink());
  assert.equal(await fs.readFile(outside, 'utf8'), 'keep me');
  assert.equal(await fs.readFile(path.join(thumbs, 'other.jpg'), 'utf8'), 'keep me');
  assert.equal(await fs.readFile(path.join(outputDir, 'other.mp4'), 'utf8'), '12345');
  assert.equal(await fs.readFile(path.join(outputDir, newest), 'utf8'), '12345');
});

test('rejects a low-space capture and reports the warning once', async (t) => {
  const { options, reports } = await fixture(t);
  const archive = await openArchive({ ...options, minFreeBytes: Number.MAX_SAFE_INTEGER });
  await assert.rejects(archive.checkSpace(), /Low recording space/);
  await archive.refresh();
  assert.equal(reports.filter((message) => message.startsWith('Low recording space')).length, 1);
});

test('preserves a pre-existing unrelated index and recording when retention is enabled', async (t) => {
  const { outputDir, options } = await fixture(t);
  const index = path.join(outputDir, 'index.html');
  const old = path.join(outputDir, filename('front', Date.now() - 12 * dayMs));
  await fs.writeFile(index, 'existing site');
  await fs.writeFile(old, 'old video');
  await assert.rejects(openArchive({ ...options, retentionDays: 1 }), /index.html already exists/);
  assert.equal(await fs.readFile(index, 'utf8'), 'existing site');
  assert.equal(await fs.readFile(old, 'utf8'), 'old video');
});

test('rejects a pre-existing unmanaged thumbnail directory without modifying its files', async (t) => {
  const { outputDir, options } = await fixture(t);
  const thumbnails = path.join(outputDir, '.tapo-thumbnails');
  const photo = path.join(thumbnails, filename('front', Date.now()).replace(/\.mp4$/, '.jpg'));
  await fs.mkdir(thumbnails, { mode: 0o700 });
  await fs.writeFile(photo, 'existing photo');
  await assert.rejects(openArchive(options), /thumbnail directory already contains other files/);
  assert.equal(await fs.readFile(photo, 'utf8'), 'existing photo');
  assert.equal((await fs.readdir(thumbnails)).length, 1);
});

const ffmpeg = process.env.TAPO_TEST_FFMPEG || 'ffmpeg';
const ffmpegAvailable = spawnSync(ffmpeg, ['-version'], { stdio: 'ignore' }).status === 0;

test('renders a JPEG from a synthetic clip on refresh', { skip: !ffmpegAvailable }, async (t) => {
  const { outputDir, options } = await fixture(t);
  const clip = filename('front', Date.now());
  execFileSync(ffmpeg, [
    '-nostdin', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=blue:s=320x180',
    '-t', '1', '-c:v', 'mpeg4', '-threads', '1', path.join(outputDir, clip),
  ]);
  const archive = await openArchive({ ...options, ffmpeg });
  const thumb = clip.replace(/\.mp4$/, '.jpg');
  const index = path.join(outputDir, 'index.html');
  assert.ok(!(await fs.readFile(index, 'utf8')).includes(thumb));
  await archive.refresh();
  const bytes = await fs.readFile(path.join(outputDir, '.tapo-thumbnails', thumb));
  assert.deepEqual([...bytes.subarray(0, 2)], [0xff, 0xd8]);
  assert.deepEqual([...bytes.subarray(-2)], [0xff, 0xd9]);
  assert.ok((await fs.readFile(index, 'utf8')).includes('.tapo-thumbnails/' + thumb));
  assert.deepEqual(await fs.readdir(archive.incomingDir), []);
});
