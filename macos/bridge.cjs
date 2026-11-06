'use strict';

const { execFile, spawn } = require('node:child_process');
const { timingSafeEqual } = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { promisify } = require('node:util');
const { TapoLiveStream } = require('homebridge-tapo-direct/dist/tapo/liveStream.js');
const { Sha256MediaSession } = require('../src/media.cjs');

const appDirectory = path.join(os.homedir(), 'Library', 'Application Support', 'Tapo Menu');
const configPath = process.env.TAPO_CONFIG || path.join(appDirectory, 'config.json');
const tokenPath = process.env.TAPO_TOKEN_FILE || path.join(appDirectory, 'camera-tokens.json');
const python = process.env.TAPO_PYTHON || 'python3';
const ffmpeg = process.env.TAPO_FFMPEG || 'ffmpeg';
const log = { debug() {}, info() {}, warn() {}, error() {} };
const execute = promisify(execFile);
const shutdown = new AbortController();
const boundary = 'tapo-frame';
const cacheDuration = 8_000;
const firstFrameTimeout = 30_000;
const jpegEnd = Buffer.from([0xff, 0xd9]);

let statusCache;
let stopActiveStream;

function readJson(filename, privateFile = false) {
  const descriptor = fs.openSync(filename, fs.constants.O_RDONLY | fs.constants.O_NONBLOCK);
  try {
    const info = fs.fstatSync(descriptor);
    if (!info.isFile() || info.size > 65_536
        || (privateFile && ((info.mode & 0o077) !== 0 || info.uid !== process.getuid()))) {
      throw new Error('Unexpected file type or permissions');
    }
    return JSON.parse(fs.readFileSync(descriptor, 'utf8'));
  } finally {
    fs.closeSync(descriptor);
  }
}

function isLanIp(host) {
  if (typeof host !== 'string' || !net.isIPv4(host)) return false;
  const [first, second] = host.split('.').map(Number);
  return first === 10 || (first === 172 && second >= 16 && second <= 31)
    || (first === 192 && second === 168);
}

function cameraConfig() {
  let cameras;
  try {
    cameras = readJson(configPath).cameras;
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
  if (!Array.isArray(cameras) || cameras.length !== 2
      || !['1', '2'].every((id) => cameras.some((camera) => camera?.id === id && isLanIp(camera.host)))
      || cameras[0].host === cameras[1].host) {
    throw new Error('Invalid camera configuration');
  }
  return ['1', '2'].map((id) => ({ id, host: cameras.find((camera) => camera.id === id).host }));
}

function readTokens() {
  try {
    const payload = readJson(tokenPath, true);
    return payload?.type === 'tapo-lat/v1' ? payload.cameras : null;
  } catch {
    return null;
  }
}

function credentialFor(camera, tokens) {
  const entry = tokens?.['camera' + camera.id];
  return entry?.host === camera.host && typeof entry.lat === 'string' && /^[!-~]{1,4096}$/.test(entry.lat)
    ? entry.lat : null;
}

async function fetchStatus(cameras) {
  const args = [path.join(__dirname, 'camera_status.py'), '--config', configPath];
  let replies = [];
  try {
    const { stdout } = await execute(python, args, {
      timeout: 6_000, maxBuffer: 65_536, signal: shutdown.signal,
    });
    const parsed = JSON.parse(stdout);
    if (Array.isArray(parsed)) replies = parsed;
  } catch {
    // Report missing readings without exposing child output to the UI.
  }
  return cameras.map((camera) => {
    const reading = replies.find((reply) => reply?.id === camera.id && reply.host === camera.host);
    const battery = reading?.batteryPercent;
    return {
      ...camera,
      batteryPercent: Number.isInteger(battery) && battery >= 0 && battery <= 100 ? battery : null,
      charging: typeof reading?.charging === 'boolean' ? reading.charging : null,
      online: reading?.online === true,
    };
  });
}

function cameraStatus(cameras) {
  const key = JSON.stringify(cameras);
  if (statusCache?.key === key && statusCache.expires > Date.now()) return statusCache.result;
  const current = { key, expires: Infinity, result: fetchStatus(cameras) };
  statusCache = current;
  current.result.then(() => { current.expires = Date.now() + cacheDuration; });
  return current.result;
}

function json(response, status, data) {
  response.writeHead(status, { 'Content-Type': 'application/json' });
  response.end(JSON.stringify(data));
}

async function streamCamera(camera, response) {
  const credential = credentialFor(camera, readTokens());
  if (!credential) {
    json(response, 403, { error: 'Sign in to TP-Link to view this camera.' });
    return;
  }

  stopActiveStream?.();
  let session;
  let live;
  let decoder;
  let finished = false;
  let firstFrame;
  let drainTimeout;
  let previousByte;

  function stop(error, status = 502) {
    if (finished) return;
    finished = true;
    clearTimeout(firstFrame);
    clearTimeout(drainTimeout);
    if (stopActiveStream === stop) stopActiveStream = undefined;
    decoder?.kill('SIGKILL');
    live?.close('Preview ended');
    session?.close();
    if (response.destroyed || response.writableEnded) return;
    if (error && !response.headersSent) json(response, status, { error });
    else response.end();
  }
  stopActiveStream = stop;
  response.once('close', stop);

  try {
    live = await TapoLiveStream.start({
      name: 'Camera ' + camera.id,
      preview: { resolution: 'HD' },
      codecDetectTimeoutMs: 16_000,
      log,
      openSession: async () => {
        session = new Sha256MediaSession({ host: camera.host, credential, connectTimeoutMs: 12_000, log });
        await session.connect();
        return session;
      },
    });
  } catch (error) {
    if (error?.name === 'TapoAuthError') {
      stop('This camera rejected its token. Sign in again to refresh it.', 403);
    } else {
      stop('Could not open this camera. Check that it is awake and on the local network.');
    }
    return;
  }
  if (finished) {
    live.close('Preview closed during startup');
    return;
  }
  if (live.ended) {
    stop('This camera stopped streaming before the preview opened.');
    return;
  }

  decoder = spawn(ffmpeg, [
    '-nostdin', '-loglevel', 'error', '-probesize', '400000', '-analyzeduration', '1500000',
    '-f', 'mpegts', '-i', 'pipe:0', '-map', '0:v:0', '-an', '-sn', '-dn',
    '-vf', 'fps=12,scale=960:-2', '-c:v', 'mjpeg', '-q:v', '6', '-threads', '1',
    '-flush_packets', '1', '-f', 'mpjpeg', '-boundary_tag', boundary, 'pipe:1',
  ], { stdio: ['pipe', 'pipe', 'ignore'] });

  firstFrame = setTimeout(() => stop('The camera did not send a playable video frame.'), firstFrameTimeout);
  decoder.once('error', () => stop('FFmpeg is not available to decode this camera.', 503));
  decoder.once('close', () => stop('The camera preview ended.'));
  decoder.stdin.on('error', () => stop('The camera decoder stopped.'));
  decoder.stdout.on('data', (data) => {
    if (finished) return;
    if (firstFrame && ((previousByte === 0xff && data[0] === 0xd9) || data.includes(jpegEnd))) {
      clearTimeout(firstFrame);
      firstFrame = undefined;
    }
    previousByte = data[data.length - 1];
    if (!response.headersSent) {
      response.writeHead(200, { 'Content-Type': 'multipart/x-mixed-replace; boundary=' + boundary });
    }
    if (!response.write(data)) {
      decoder.stdout.pause();
      response.once('drain', () => decoder.stdout.resume());
    }
  });
  function feed(packets) {
    if (finished || decoder.stdin.destroyed) return;
    if (decoder.stdin.writableLength > 8 * 1024 * 1024) {
      stop('The decoder could not keep up with the camera.');
      return;
    }
    decoder.stdin.write(packets);
  }
  function finishInput() {
    if (finished || drainTimeout) return;
    drainTimeout = setTimeout(() => stop('The camera preview ended.'), 3000);
    if (!decoder.stdin.destroyed) decoder.stdin.end();
  }
  live.once('end', finishInput);
  live.once('error', finishInput);
  feed(live.getStartupPackets());
  if (!finished) live.on('ts', feed);
}

function main() {
  const secret = process.env.TAPO_BRIDGE_TOKEN;
  if (!secret || !/^[A-Za-z0-9_-]{32,128}$/.test(secret)) {
    throw new Error('A private session token is required.');
  }
  delete process.env.TAPO_BRIDGE_TOKEN;
  const expected = Buffer.from('Bearer ' + secret);
  const server = http.createServer(async (request, response) => {
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    const authorization = Buffer.from(request.headers.authorization || '');
    if (request.headers.host !== '127.0.0.1:' + server.address().port
        || authorization.length !== expected.length || !timingSafeEqual(authorization, expected)) {
      json(response, 401, { error: 'Invalid preview session.' });
      return;
    }
    if (request.method !== 'GET') {
      json(response, 405, { error: 'Method is not supported.' });
      return;
    }
    try {
      if (request.url === '/status') {
        const cameras = cameraConfig();
        if (!cameras) {
          json(response, 200, { cameras: [], hasCredentials: false });
          return;
        }
        const status = await cameraStatus(cameras);
        if (response.destroyed) return;
        const tokens = readTokens();
        json(response, 200, {
          cameras: status,
          hasCredentials: cameras.every((camera) => credentialFor(camera, tokens)),
        });
        return;
      }
      const match = /^\/live\/([12])$/.exec(request.url);
      if (match) {
        const cameras = cameraConfig();
        if (!cameras) {
          json(response, 409, { error: 'Set up Tapo Menu before opening a preview.' });
          return;
        }
        await streamCamera(cameras.find((camera) => camera.id === match[1]), response);
      } else {
        json(response, 404, { error: 'Unknown preview path.' });
      }
    } catch {
      if (!response.destroyed && !response.headersSent) {
        json(response, 500, { error: 'Could not load the camera configuration.' });
      } else if (!response.destroyed) {
        response.end();
      }
    }
  });
  server.on('error', () => {
    console.error('Could not start the local camera preview.');
    process.exitCode = 1;
  });
  server.listen(0, '127.0.0.1', () => {
    process.stdout.write(JSON.stringify({ port: server.address().port }) + '\n');
  });
  const parent = process.ppid;
  const parentMonitor = setInterval(() => {
    if (process.ppid !== parent) stop();
  }, 3_000);
  parentMonitor.unref();
  function stop() {
    clearInterval(parentMonitor);
    shutdown.abort();
    stopActiveStream?.();
    server.close();
    server.closeAllConnections();
  }
  process.once('SIGINT', stop);
  process.once('SIGTERM', stop);
}

if (require.main === module) {
  try {
    main();
  } catch {
    console.error('Could not start the local camera preview.');
    process.exitCode = 1;
  }
}
