'use strict';

const { spawn } = require('node:child_process');
const { randomBytes } = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');
const { createInterface } = require('node:readline');
const { setTimeout: delay } = require('node:timers/promises');
const { openArchive } = require('./archive.cjs');

const CLIP_SECONDS = 15;
const MAX_ALARM_TIMESTAMP = 253402300799;
const MAX_EVENT_AGE_MS = 60_000;
const MAX_CAPTURE_ATTEMPTS = 3;
const RETRY_DELAY_MS = 1_000;
const COALESCE_SECONDS = 3;

class CaptureError extends Error {
  constructor(message, retryable = false) {
    super(message);
    this.retryable = retryable;
  }
}

function muxClip(ffmpeg, live, destination, seconds, signal) {
  return new Promise((resolve, reject) => {
    const videoTag = live.info.videoCodec === 'h265' ? ['-tag:v', 'hvc1'] : [];
    const muxer = spawn(ffmpeg, [
      '-nostdin', '-y', '-loglevel', 'error', '-probesize', '400000', '-analyzeduration', '1500000',
      '-f', 'mpegts', '-i', 'pipe:0', '-map', '0:v:0', '-an', '-c:v', 'copy', ...videoTag,
      '-t', String(seconds), '-movflags', '+faststart', '-f', 'mp4', destination,
    ], { stdio: ['pipe', 'ignore', 'ignore'] });
    const endInput = () => muxer.stdin.end();
    const abort = () => muxer.kill('SIGKILL');
    const inputTimeout = Math.max(24_000, (seconds + 9) * 1000);
    const inputDeadline = setTimeout(endInput, inputTimeout);
    const finalDeadline = setTimeout(abort, inputTimeout + 6_000);

    function feed(packets) {
      if (muxer.stdin.destroyed || muxer.stdin.writableEnded) return;
      if (muxer.stdin.writableLength > 12 * 1024 * 1024) {
        endInput();
        return;
      }
      muxer.stdin.write(packets);
    }

    // FFmpeg closes its input when it reaches the clip length, which can cause EPIPE.
    muxer.stdin.on('error', () => {});
    muxer.on('error', () => reject(new CaptureError('FFmpeg could not start.')));
    muxer.once('close', (code) => {
      clearTimeout(inputDeadline);
      clearTimeout(finalDeadline);
      signal.removeEventListener('abort', abort);
      live.off('ts', feed);
      live.off('end', endInput);
      live.off('error', endInput);
      resolve(code === 0 && !signal.aborted);
    });
    signal.addEventListener('abort', abort, { once: true });
    if (signal.aborted) {
      abort();
      return;
    }
    live.on('end', endInput);
    live.on('error', endInput);
    feed(live.getStartupPackets());
    live.on('ts', feed);
    if (live.ended) endInput();
  });
}

function hasDecodableFrame(ffmpeg, filename, signal) {
  return new Promise((resolve, reject) => {
    const decoder = spawn(ffmpeg, [
      '-nostdin', '-loglevel', 'error', '-xerror', '-progress', 'pipe:1',
      '-i', filename, '-map', '0:v:0', '-an', '-frames:v', '1', '-f', 'null', '-',
    ], { stdio: ['ignore', 'pipe', 'ignore'] });
    const abort = () => decoder.kill('SIGKILL');
    const deadline = setTimeout(abort, 8_000);
    let progress = '';
    decoder.stdout.setEncoding('utf8');
    decoder.stdout.on('data', (chunk) => { progress += chunk; });
    decoder.on('error', () => reject(new CaptureError('FFmpeg could not start.')));
    decoder.once('close', (code) => {
      clearTimeout(deadline);
      signal.removeEventListener('abort', abort);
      resolve(code === 0 && !signal.aborted && /^frame=\s*[1-9]\d*$/m.test(progress));
    });
    signal.addEventListener('abort', abort, { once: true });
    if (signal.aborted) abort();
  });
}

async function existingClip(filename) {
  const stat = await fs.lstat(filename);
  if (!stat.isFile()) throw new CaptureError('The recording target is not a regular file.');
  return { filename, completedAt: stat.mtime.toISOString(), created: false };
}

async function saveClip({ camera, alarm, openPreview, ffmpeg, outputDir, archive, clipSeconds, signal, report }) {
  const timestamp = new Date(alarm * 1000).toISOString().replace(/[:.]/g, '-');
  const basename = `camera-${camera.id}_${timestamp}`;
  const destination = path.join(outputDir, `${basename}.mp4`);
  const partial = path.join(archive.incomingDir, `.${basename}.${randomBytes(6).toString('hex')}.partial`);
  try {
    return await existingClip(destination);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  if (signal.aborted) return null;

  try {
    await archive.checkSpace();
  } catch (error) {
    throw new CaptureError(error.message);
  }
  if (signal.aborted) return null;
  const file = await fs.open(partial, 'wx', 0o600);
  let live;
  try {
    await file.close();
    const openingStarted = performance.now();
    try {
      live = await openPreview(camera, signal);
    } catch (error) {
      if (error?.name === 'TapoAuthError') throw new CaptureError('Camera rejected its access token.');
      throw new CaptureError('Could not open the camera stream.', true);
    }
    report(`Camera ${camera.id}: video stream ready in ${Math.round(performance.now() - openingStarted)} ms.`);
    if (signal.aborted) return null;
    const muxed = await muxClip(ffmpeg, live, partial, clipSeconds, signal);
    live.close('motion clip capture finished');
    live = null;
    if (!muxed || !(await hasDecodableFrame(ffmpeg, partial, signal))) {
      if (signal.aborted) return null;
      throw new CaptureError('No valid video in the motion clip.', true);
    }
    try {
      await fs.link(partial, destination);
    } catch (error) {
      if (error.code === 'EEXIST') return existingClip(destination);
      throw error;
    }
    return { filename: destination, completedAt: new Date().toISOString(), created: true };
  } finally {
    live?.close('motion clip capture stopped');
    await fs.rm(partial, { force: true });
  }
}

async function loadClipHistory(statusFile) {
  if (!statusFile) return [];
  try {
    const stat = await fs.lstat(statusFile);
    if (!stat.isFile() || stat.uid !== process.getuid() || stat.mode & 0o077 || stat.size > 65_536) return [];
    const previous = JSON.parse(await fs.readFile(statusFile, 'utf8'));
    return previous.version === 1 && Array.isArray(previous.cameras) ? previous.cameras : [];
  } catch {
    return [];
  }
}

async function writeStatusFile(filename, contents) {
  const directory = path.dirname(filename);
  const partial = path.join(directory, `.${path.basename(filename)}.${randomBytes(6).toString('hex')}.partial`);
  try {
    await fs.writeFile(partial, contents, { encoding: 'utf8', mode: 0o600, flag: 'wx' });
    await fs.rename(partial, filename);
  } finally {
    await fs.rm(partial, { force: true });
  }
}

function captureFailure(error) {
  if (error instanceof CaptureError) return error.message.slice(0, 200);
  if (typeof error?.code === 'string' && /^[A-Z0-9_]{1,24}$/.test(error.code)) {
    return `Could not write the clip (${error.code}).`;
  }
  return 'Unexpected capture failure.';
}

function isFresh(job) {
  return performance.now() - job.receivedAt < MAX_EVENT_AGE_MS;
}

async function startMotionRecorder({
  cameras, openPreview, ffmpeg, report, watchPath, outputDir,
  pollIntervalMs = 250, clipSeconds = CLIP_SECONDS, statusFile, onReady = async () => {},
  retentionDays, maxStorageBytes, minFreeBytes,
}) {
  const archive = await openArchive({ outputDir, cameras, ffmpeg, retentionDays, maxStorageBytes, minFreeBytes, report });
  const priorClips = await loadClipHistory(statusFile);
  const byHost = new Map(cameras.map((camera) => {
    const saved = priorClips.find((entry) => entry?.id === camera.id && entry.host === camera.host);
    const health = {
      id: camera.id,
      name: camera.name || `Camera ${camera.id}`,
      host: camera.host,
      lastReplyAt: null,
      lastAlarmAt: null,
      lastClipAt: null,
      lastClip: null,
      lastError: null,
      lastErrorAt: null,
      probeError: null,
      probeErrorAt: null,
    };
    if (typeof saved?.lastClip === 'string' && saved.lastClip.length <= 128
        && path.basename(saved.lastClip) === saved.lastClip && saved.lastClip.startsWith(`camera-${camera.id}_`)
        && typeof saved.lastClipAt === 'string' && Number.isFinite(Date.parse(saved.lastClipAt))) {
      health.lastClip = saved.lastClip;
      health.lastClipAt = new Date(saved.lastClipAt).toISOString();
    }
    return [camera.host, { camera, health, pending: null, worker: null, lastAlarm: 0 }];
  }));
  let recorderState = 'starting';
  let statusWrite = Promise.resolve();
  let statusDirty = false;
  let statusBusy = false;
  let lastPublished = -Infinity;
  function publishStatus() {
    if (!statusFile) return Promise.resolve();
    statusDirty = false;
    lastPublished = performance.now();
    const contents = JSON.stringify({
      version: 1,
      state: recorderState,
      updatedAt: new Date().toISOString(),
      cameras: [...byHost.values()].map(({ health }) => health),
    }, null, 2) + '\n';
    const write = statusWrite.then(() => writeStatusFile(statusFile, contents));
    statusWrite = write.catch(() => report('Could not update recorder status.'));
    return write;
  }
  if (statusFile) {
    await fs.mkdir(path.dirname(statusFile), { recursive: true, mode: 0o700 });
    await publishStatus();
  }

  const controller = new AbortController();
  const { signal } = controller;
  const watcher = spawn('python3', ['-u', watchPath, '--events', '--interval', String(pollIntervalMs / 1000), ...byHost.keys()], {
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  const lines = createInterface({ input: watcher.stdout, crlfDelay: Infinity });
  const watchClosed = new Promise((resolve) => {
    watcher.on('error', () => report('Could not start the motion watcher.'));
    watcher.once('close', resolve);
  });
  let markReady;
  const watchReady = new Promise((resolve) => { markReady = resolve; });
  let startupTimer;
  const startupExpired = new Promise((resolve) => {
    startupTimer = setTimeout(() => resolve(false), 10_000);
  });
  const statusTimer = setInterval(() => {
    if (statusFile && !statusBusy && (statusDirty || performance.now() - lastPublished >= 30_000)) {
      statusBusy = true;
      void publishStatus().catch(() => {}).finally(() => { statusBusy = false; });
    }
  }, 1_000);
  statusTimer.unref();
  let archiveWork;
  let archiveDirty = false;
  function refreshArchive() {
    if (signal.aborted) return;
    archiveDirty = true;
    if (archiveWork) return;
    archiveWork = (async () => {
      do {
        archiveDirty = false;
        try {
          await archive.refresh();
        } catch {
          report('Could not refresh the recording archive.');
        }
      } while (archiveDirty && !signal.aborted);
    })().finally(() => { archiveWork = null; });
  }
  const archiveTimer = setInterval(refreshArchive, 60_000);
  archiveTimer.unref();
  function stop() {
    controller.abort();
    watcher.kill();
  }
  function noteCaptureFailure(state, reason) {
    state.health.lastError = reason;
    state.health.lastErrorAt = new Date().toISOString();
    statusDirty = true;
    report(`Camera ${state.camera.id}: motion clip could not be saved. ${reason}`);
  }
  let acceptingCaptures = false;
  async function capturePending(state) {
    const { camera } = state;
    while (state.pending && !signal.aborted) {
      const job = state.pending;
      state.pending = null;
      if (!isFresh(job)) {
        noteCaptureFailure(state, 'Motion event expired before capture could begin.');
        continue;
      }
      report(`Camera ${camera.id}: motion detected, opening video.`);
      for (let attempt = 1; attempt <= MAX_CAPTURE_ATTEMPTS && !signal.aborted; attempt++) {
        try {
          const clip = await saveClip({
            camera, alarm: job.alarm, openPreview, ffmpeg, outputDir, archive, clipSeconds, signal, report,
          });
          if (!clip) break;
          state.health.lastClip = path.basename(clip.filename);
          state.health.lastClipAt = clip.completedAt;
          statusDirty = true;
          if (state.pending && state.pending.alarm - job.alarm <= COALESCE_SECONDS) state.pending = null;
          if (clip.created) {
            report(`Camera ${camera.id}: saved ${clip.filename}`);
            refreshArchive();
          }
          break;
        } catch (error) {
          if (signal.aborted) break;
          noteCaptureFailure(state, captureFailure(error));
          if (!error?.retryable || attempt === MAX_CAPTURE_ATTEMPTS || state.pending || !isFresh(job)) break;
          await delay(RETRY_DELAY_MS, undefined, { signal }).catch(() => {});
          if (signal.aborted || state.pending || !isFresh(job)) break;
          report(`Camera ${camera.id}: retrying motion capture.`);
        }
      }
    }
  }
  function startCapture(state) {
    if (!acceptingCaptures || state.worker || !state.pending || signal.aborted) return;
    state.worker = capturePending(state)
      .catch(() => noteCaptureFailure(state, 'Unexpected capture failure.'))
      .finally(() => {
        state.worker = null;
        startCapture(state);
      });
  }

  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
  lines.on('line', (line) => {
    if (signal.aborted) return;
    let event;
    try { event = JSON.parse(line); } catch { return; }
    if (event?.type === 'ready') {
      markReady(true);
      return;
    }
    const state = byHost.get(event?.host);
    if (!state) return;
    const now = new Date().toISOString();
    if (event.type === 'error' && typeof event.reason === 'string') {
      state.health.probeError = event.reason.slice(0, 200);
      state.health.probeErrorAt = now;
      statusDirty = true;
      return;
    }
    if (event.type !== 'reply') return;
    state.health.lastReplyAt = now;
    state.health.probeError = null;
    state.health.probeErrorAt = null;
    statusDirty = true;
    const alarm = event?.alarm;
    if (!Number.isSafeInteger(alarm) || alarm <= state.lastAlarm || alarm > MAX_ALARM_TIMESTAMP) return;
    state.lastAlarm = alarm;
    state.health.lastAlarmAt = new Date(alarm * 1000).toISOString();
    if (event.motion !== true) return;
    state.pending = { alarm, receivedAt: performance.now() };
    startCapture(state);
  });

  try {
    const initialized = await Promise.race([watchReady, watchClosed.then(() => false), startupExpired]);
    clearTimeout(startupTimer);
    if (signal.aborted) return;
    if (!initialized) throw new Error('Motion watcher did not initialize.');
    recorderState = 'running';
    await publishStatus();
    if (signal.aborted) return;
    await onReady();
    acceptingCaptures = true;
    refreshArchive();
    for (const state of byHost.values()) startCapture(state);
    report(`Motion recorder is watching ${byHost.size} cameras every ${pollIntervalMs} ms. Clips go to ${outputDir}`);
    const code = await watchClosed;
    if (!signal.aborted) {
      throw new Error(`Motion watcher exited unexpectedly (${code ?? 'signal'})`);
    }
  } catch (error) {
    recorderState = 'failed';
    throw error;
  } finally {
    stop();
    clearTimeout(startupTimer);
    clearInterval(statusTimer);
    clearInterval(archiveTimer);
    lines.close();
    const workers = [...byHost.values()].map(({ worker }) => worker);
    await Promise.allSettled([watchClosed, archiveWork, ...workers]);
    if (recorderState !== 'failed') recorderState = 'stopped';
    await publishStatus().catch(() => {});
    process.off('SIGINT', stop);
    process.off('SIGTERM', stop);
    report('Motion recorder stopped.');
  }
}

module.exports = { startMotionRecorder };
