'use strict';

const { execFile, spawn } = require('node:child_process');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { promisify } = require('node:util');
const { TapoLiveStream } = require('homebridge-tapo-direct/dist/tapo/liveStream.js');
const { Sha256MediaSession } = require('./media.cjs');
const { startMotionRecorder } = require('./record.cjs');

const watchPath = path.join(__dirname, '..', 'watch_detection.py');
const quiet = { debug() {}, info() {}, warn() {}, error() {} };
const report = (message) => console.log(new Date().toISOString(), message);
const execute = promisify(execFile);
const mib = 1024 * 1024;

function readJson(filename, description, forbiddenMode = 0) {
  try {
    const fd = fs.openSync(filename, fs.constants.O_RDONLY | fs.constants.O_NONBLOCK);
    try {
      const metadata = fs.fstatSync(fd);
      if (!metadata.isFile() || metadata.size > 64 * 1024) throw new Error();
      if (metadata.mode & forbiddenMode) {
        throw new Error('Credential permissions are too broad');
      }
      const data = JSON.parse(fs.readFileSync(fd, 'utf8'));
      if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error();
      return data;
    } finally {
      fs.closeSync(fd);
    }
  } catch (error) {
    const hint = error.message === 'Credential permissions are too broad' ? ' ' + error.message + '.' : '';
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
  return cameras.map(({ id, host, name }) => {
    if (name !== undefined && (
      typeof name !== 'string' || !name.trim() || [...name].length > 80 || /[\u0000-\u001f\u007f]/.test(name)
    )) {
      throw new Error(`Camera ${id} needs a name of 1–80 characters.`);
    }
    return { id, host, name: name?.trim() || `Cam ${id}` };
  });
}

function credentialsPath(configPath) {
  const fallback = process.env.TAPO_CONFIG
    ? '/etc/tapo-recorder/camera-tokens.json'
    : path.join(path.dirname(configPath), 'camera-tokens.json');
  return process.env.TAPO_TOKEN_FILE || (process.env.CREDENTIALS_DIRECTORY
    ? path.join(process.env.CREDENTIALS_DIRECTORY, 'camera-tokens.json')
    : fallback);
}

function readCredentials(cameras, filename) {
  const directory = path.dirname(filename);
  // LoadCredential uses a root-owned directory and may grant the service user
  // access by ACL. stat reports that ACL mask as the group-read mode bit.
  const managed = !process.env.TAPO_TOKEN_FILE && directory === process.env.CREDENTIALS_DIRECTORY
    && /^\/run\/(?:user\/\d+\/)?credentials\/[^/]+$/.test(directory)
    && path.normalize(directory) === directory;
  let forbiddenMode = 0o077;
  if (managed) {
    const metadata = fs.lstatSync(directory);
    if (metadata.isDirectory() && (metadata.uid === 0 || metadata.uid === process.getuid())
        && (metadata.mode & 0o027) === 0) forbiddenMode = 0o037;
  }
  const payload = readJson(filename, 'camera credential file', forbiddenMode);
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
    const deadline = setTimeout(() => child.kill('SIGKILL'), 30_000);
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
      report(`${camera.name} (${camera.host}): decoded a video frame.`);
      return true;
    }
    report(`${camera.name} (${camera.host}): no video frame decoded.`);
  } catch (error) {
    const reason = error?.name === 'TapoAuthError'
      ? 'camera rejected its token'
      : 'no usable stream; check the subnet route and wake the camera';
    report(`${camera.name} (${camera.host}): ${reason}.`);
  } finally {
    stream?.close('frame check finished');
  }
  return false;
}

function configurationPath() {
  if (process.env.TAPO_CONFIG) return process.env.TAPO_CONFIG;
  const home = process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config');
  const userConfig = path.join(home, 'tapo-motion-recorder', 'current', 'config.json');
  return fs.existsSync(userConfig) ? userConfig : '/etc/tapo-recorder/config.json';
}

function integerSetting(config, key, fallback, minimum, maximum) {
  const value = config[key] ?? fallback;
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new Error(`Config ${key} must be an integer from ${minimum} to ${maximum}.`);
  }
  return value;
}

function includesPath(directory, filename) {
  const relative = path.relative(directory, filename);
  return relative === '' || (relative !== '..' && !relative.startsWith('..' + path.sep) && !path.isAbsolute(relative));
}

function existingAncestorPath(filename) {
  const resolved = path.resolve(filename);
  if (fs.existsSync(resolved)) return fs.realpathSync(resolved);
  return path.join(existingAncestorPath(path.dirname(resolved)), path.basename(resolved));
}

function archiveSettings(config, configPath, tokenPath) {
  if (typeof config.recordingsDir !== 'string' || !path.isAbsolute(config.recordingsDir)) {
    throw new Error('Config recordingsDir must be an absolute path.');
  }
  const outputDir = path.resolve(config.recordingsDir);
  const statusFile = config.statusFile ?? path.join(path.dirname(outputDir), 'status.json');
  if (typeof statusFile !== 'string' || !path.isAbsolute(statusFile)) {
    throw new Error('Config statusFile must be an absolute path.');
  }
  const realOutput = existingAncestorPath(outputDir);
  if ([configPath, tokenPath, statusFile].some((filename) =>
    includesPath(outputDir, filename) || includesPath(realOutput, existingAncestorPath(filename))
  )) {
    throw new Error('Choose a dedicated recordings folder outside the config, credential and status files.');
  }
  return {
    outputDir, statusFile,
    clipSeconds: integerSetting(config, 'clipSeconds', 15, 1, 120),
    retentionDays: integerSetting(config, 'retentionDays', 0, 0, 36500),
    maxStorageBytes: integerSetting(config, 'maxStorageBytes', 0, 0, Number.MAX_SAFE_INTEGER),
    minFreeBytes: integerSetting(config, 'minFreeBytes', 256 * mib, 0, Number.MAX_SAFE_INTEGER),
  };
}

function printStatus(statusFile, pollIntervalMs) {
  const status = readJson(statusFile, 'recorder status; start the recorder first');
  const stale = Math.max(30_000, pollIntervalMs * 3);
  const now = Date.now();
  console.log(JSON.stringify({
    ...status,
    stale: !status.updatedAt || now - Date.parse(status.updatedAt) > 60_000,
    cameras: (status.cameras || []).map((camera) => ({
      ...camera,
      replyStale: !camera.lastReplyAt || now - Date.parse(camera.lastReplyAt) > stale,
    })),
  }, null, 2));
}

async function checkLocalSetup(cameras, { outputDir, minFreeBytes }, ffmpeg) {
  let writable = false;
  try {
    fs.accessSync(outputDir, fs.constants.W_OK | fs.constants.X_OK);
    const storage = fs.statfsSync(outputDir);
    const free = storage.bavail * storage.bsize;
    writable = free >= minFreeBytes;
    report(`Storage: ${outputDir} has ${Math.floor(free / mib)} MiB available.`);
    if (!writable) report(`Storage is below the configured ${Math.ceil(minFreeBytes / mib)} MiB reserve.`);
  } catch {
    report(`Storage: ${outputDir} is unavailable or not writable.`);
  }

  const replies = new Set();
  try {
    const { stdout } = await execute('python3', [
      watchPath, '--events', '--seconds', '4', ...cameras.map((camera) => camera.host),
    ], { timeout: 10_000, maxBuffer: 128 * 1024 });
    for (const line of stdout.trim().split('\n')) {
      const event = JSON.parse(line);
      if (event.type === 'reply') replies.add(event.host);
    }
  } catch {
    report('Discovery check could not complete. Check Python and OpenSSL.');
  }
  for (const camera of cameras) {
    report(`${camera.name} (${camera.host}): ${replies.has(camera.host) ? 'replied on UDP 20004' : 'no UDP reply; check its route or wake the camera'}.`);
  }
  let decoderReady = true;
  try {
    await execute(ffmpeg, ['-version'], { timeout: 5000, maxBuffer: 64 * 1024 });
    report('Video decoder: FFmpeg is available.');
  } catch {
    decoderReady = false;
    report('Video decoder: could not run FFmpeg.');
  }
  return { localReady: writable && cameras.every(({ host }) => replies.has(host)), decoderReady };
}

async function notifyReady() {
  if (process.env.NOTIFY_SOCKET) {
    await execute('systemd-notify', ['--ready', '--status=Recording storage and motion watcher ready'], {
      timeout: 5000,
    });
  }
}

async function main() {
  const [mode, ...extra] = process.argv.slice(2);
  if (extra.length || (mode && !['--check', '--status', '--doctor'].includes(mode))) {
    throw new Error('Usage: tapo-motion-recorder [--check|--status|--doctor]');
  }
  const configPath = configurationPath();
  const config = readJson(configPath, 'config');
  const cameras = readCameras(config);
  const pollIntervalMs = integerSetting(config, 'pollIntervalMs', 250, 100, 60_000);
  const tokenPath = credentialsPath(configPath);
  const archive = mode === '--check' ? null : archiveSettings(config, configPath, tokenPath);
  if (mode === '--status') {
    printStatus(archive.statusFile, pollIntervalMs);
    return;
  }

  const ffmpeg = process.env.TAPO_FFMPEG || 'ffmpeg';
  const { localReady, decoderReady } = mode === '--doctor'
    ? await checkLocalSetup(cameras, archive, ffmpeg)
    : { localReady: true, decoderReady: true };
  if (!decoderReady) {
    process.exitCode = 1;
    return;
  }
  const credentials = readCredentials(cameras, tokenPath);
  const openPreview = (camera) => openStream(camera, credentials.get(camera.id));
  if (mode === '--check' || mode === '--doctor') {
    const results = await Promise.all(cameras.map((camera) => checkCamera(camera, openPreview, ffmpeg)));
    if (!localReady || !results.every(Boolean)) process.exitCode = 1;
    return;
  }

  await startMotionRecorder({
    ...archive, cameras, openPreview, ffmpeg, report, watchPath, pollIntervalMs, onReady: notifyReady,
  });
}

main().catch((error) => {
  // Only our configuration and watcher messages are expected to reach here.
  // Camera responses and tokens are never logged.
  console.error('Tapo recorder:', error.message);
  process.exitCode = 1;
});
