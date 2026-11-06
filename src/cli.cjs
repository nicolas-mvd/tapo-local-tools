'use strict';

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');
const { TapoLiveStream } = require('homebridge-tapo-direct/dist/tapo/liveStream.js');
const { Sha256MediaSession } = require('./media.cjs');
const { startMotionRecorder } = require('./record.cjs');

const watchPath = path.join(__dirname, '..', 'watch_detection.py');
const quiet = { debug() {}, info() {}, warn() {}, error() {} };
const report = (message) => console.log(new Date().toISOString(), message);

function readJson(filename, description, privateFile = false) {
  try {
    const fd = fs.openSync(filename, 'r');
    try {
      const metadata = fs.fstatSync(fd);
      if (!metadata.isFile() || metadata.size > 64 * 1024) throw new Error();
      if (privateFile && (metadata.mode & 0o077)) {
        throw new Error('Permissions must be 0600 or stricter');
      }
      const data = JSON.parse(fs.readFileSync(fd, 'utf8'));
      if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error();
      return data;
    } finally {
      fs.closeSync(fd);
    }
  } catch (error) {
    const hint = error.message === 'Permissions must be 0600 or stricter' ? ' ' + error.message + '.' : '';
    throw new Error(`Could not read ${description} at ${filename}.${hint}`);
  }
}

function isLanIp(host) {
  if (typeof host !== 'string' || !net.isIPv4(host)) return false;
  const [first, second] = host.split('.').map(Number);
  return first === 10 || (first === 172 && second >= 16 && second <= 31)
    || (first === 192 && second === 168);
}

function readCameras(config) {
  const cameras = config.cameras;
  if (!Array.isArray(cameras) || !cameras.length || cameras.length > 16
      || cameras.some((camera) => !camera || typeof camera.id !== 'string'
        || !/^[a-z0-9][a-z0-9-]{0,23}$/i.test(camera.id) || !isLanIp(camera.host))
      || new Set(cameras.map((camera) => camera.id)).size !== cameras.length
      || new Set(cameras.map((camera) => camera.host)).size !== cameras.length) {
    throw new Error('Config needs unique camera IDs and private IPv4 addresses.');
  }
  return cameras;
}

function readCredentials(cameras) {
  const filename = process.env.TAPO_TOKEN_FILE || (process.env.CREDENTIALS_DIRECTORY
    ? path.join(process.env.CREDENTIALS_DIRECTORY, 'camera-tokens.json')
    : '/etc/tapo-recorder/camera-tokens.json');
  const payload = readJson(filename, 'camera credential file', true);
  if (payload.type !== 'tapo-lat/v1' || !payload.cameras) {
    throw new Error('Camera credential file format is invalid.');
  }
  return new Map(cameras.map(({ id, host }) => {
    const entry = payload.cameras['camera' + id];
    if (entry?.host !== host || typeof entry.lat !== 'string' || !/^[!-~]{1,4096}$/.test(entry.lat)) {
      throw new Error(`Camera ${id} needs a local access token for ${host}.`);
    }
    return [id, entry.lat];
  }));
}

function openStream(camera, credential) {
  return TapoLiveStream.start({
    name: 'Camera ' + camera.id,
    preview: { resolution: 'HD' },
    log: quiet,
    codecDetectTimeoutMs: 16_000,
    openSession: () => Sha256MediaSession.open({
      host: camera.host, credential, connectTimeoutMs: 12_000, log: quiet,
    }),
  });
}

function decodeFrame(ffmpeg, stream) {
  return new Promise((resolve) => {
    const child = spawn(ffmpeg, [
      '-nostdin', '-loglevel', 'error', '-probesize', '400000', '-analyzeduration', '1500000',
      '-progress', 'pipe:1', '-f', 'mpegts', '-i', 'pipe:0',
      '-map', '0:v:0', '-an', '-frames:v', '1', '-f', 'null', '-',
    ], { stdio: ['pipe', 'pipe', 'ignore'] });
    let progress = '';
    const feed = (packets) => {
      if (!child.stdin.destroyed && !child.stdin.writableEnded) child.stdin.write(packets);
    };
    const end = () => child.stdin.end();
    const deadline = setTimeout(() => child.kill('SIGKILL'), 18_000);
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => { progress += chunk; });
    child.stdin.on('error', () => {});
    child.on('error', () => {});
    child.once('close', (code) => {
      clearTimeout(deadline);
      stream.off('ts', feed);
      stream.off('end', end);
      stream.off('error', end);
      resolve(code === 0 && /^frame=\s*[1-9]\d*$/m.test(progress));
    });
    stream.on('end', end);
    stream.on('error', end);
    feed(stream.getStartupPackets());
    stream.on('ts', feed);
    if (stream.ended) end();
  });
}

async function checkCamera(camera, openPreview, ffmpeg) {
  let stream;
  try {
    stream = await openPreview(camera);
    if (await decodeFrame(ffmpeg, stream)) {
      report(`Camera ${camera.id} (${camera.host}): decoded a video frame.`);
      return true;
    }
    report(`Camera ${camera.id} (${camera.host}): no video frame decoded.`);
  } catch (error) {
    const reason = error?.name === 'TapoAuthError'
      ? 'camera rejected its token'
      : 'no usable stream; check the subnet route and wake the camera';
    report(`Camera ${camera.id} (${camera.host}): ${reason}.`);
  } finally {
    stream?.close('frame check finished');
  }
  return false;
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length > 1 || (args.length && args[0] !== '--check')) {
    throw new Error('Usage: tapo-motion-recorder [--check]');
  }
  const config = readJson(process.env.TAPO_CONFIG || '/etc/tapo-recorder/config.json', 'config');
  const cameras = readCameras(config);
  const pollIntervalMs = config.pollIntervalMs ?? 250;
  if (!Number.isInteger(pollIntervalMs) || pollIntervalMs < 100 || pollIntervalMs > 60_000) {
    throw new Error('Config pollIntervalMs must be an integer between 100 and 60000.');
  }
  const credentials = readCredentials(cameras);
  const openPreview = (camera) => openStream(camera, credentials.get(camera.id));
  const ffmpeg = process.env.TAPO_FFMPEG || 'ffmpeg';
  if (args[0] === '--check') {
    const results = await Promise.all(cameras.map((camera) => checkCamera(camera, openPreview, ffmpeg)));
    if (!results.every(Boolean)) process.exitCode = 1;
    return;
  }

  if (typeof config.recordingsDir !== 'string' || !path.isAbsolute(config.recordingsDir)) {
    throw new Error('Config recordingsDir must be an absolute path.');
  }
  await startMotionRecorder({ cameras, openPreview, ffmpeg, report, watchPath, outputDir: config.recordingsDir, pollIntervalMs });
}

main().catch((error) => {
  // Only our configuration and watcher messages are expected to reach here.
  // Camera responses and tokens are never logged.
  console.error('Tapo recorder:', error.message);
  process.exitCode = 1;
});
