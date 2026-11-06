'use strict';

const { spawn } = require('node:child_process');
const { randomBytes } = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');
const { createInterface } = require('node:readline');

const CLIP_SECONDS = 15;

function muxClip(ffmpeg, live, destination, signal) {
  return new Promise((resolve) => {
    const videoTag = live.info.videoCodec === 'h265' ? ['-tag:v', 'hvc1'] : [];
    const muxer = spawn(ffmpeg, [
      '-nostdin', '-y', '-loglevel', 'error', '-probesize', '400000', '-analyzeduration', '1500000',
      '-f', 'mpegts', '-i', 'pipe:0', '-map', '0:v:0', '-an', '-c:v', 'copy', ...videoTag,
      '-t', String(CLIP_SECONDS), '-movflags', '+faststart', '-f', 'mp4', destination,
    ], { stdio: ['pipe', 'ignore', 'ignore'] });
    const endInput = () => muxer.stdin.end();
    const abort = () => muxer.kill('SIGKILL');
    const inputDeadline = setTimeout(endInput, 24_000);
    const finalDeadline = setTimeout(abort, 30_000);

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
    muxer.on('error', () => {});
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
  return new Promise((resolve) => {
    const decoder = spawn(ffmpeg, [
      '-nostdin', '-loglevel', 'error', '-xerror', '-progress', 'pipe:1',
      '-i', filename, '-map', '0:v:0', '-an', '-frames:v', '1', '-f', 'null', '-',
    ], { stdio: ['ignore', 'pipe', 'ignore'] });
    const abort = () => decoder.kill('SIGKILL');
    const deadline = setTimeout(abort, 8_000);
    let progress = '';
    decoder.stdout.setEncoding('utf8');
    decoder.stdout.on('data', (chunk) => { progress += chunk; });
    decoder.on('error', () => {});
    decoder.once('close', (code) => {
      clearTimeout(deadline);
      signal.removeEventListener('abort', abort);
      resolve(code === 0 && !signal.aborted && /^frame=\s*[1-9]\d*$/m.test(progress));
    });
    signal.addEventListener('abort', abort, { once: true });
    if (signal.aborted) abort();
  });
}

async function saveClip({ camera, alarm, openPreview, ffmpeg, outputDir, incomingDir, signal, report }) {
  const timestamp = new Date(alarm * 1000).toISOString().replace(/[:.]/g, '-');
  const basename = `camera-${camera.id}_${timestamp}`;
  const destination = path.join(outputDir, `${basename}.mp4`);
  const partial = path.join(incomingDir, `.${basename}.${randomBytes(6).toString('hex')}.partial`);
  try {
    await fs.access(destination);
    return null;
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  if (signal.aborted) return null;

  const file = await fs.open(partial, 'wx', 0o600);
  let live;
  try {
    await file.close();
    const openingStarted = performance.now();
    live = await openPreview(camera);
    report(`Camera ${camera.id}: video stream ready in ${Math.round(performance.now() - openingStarted)} ms.`);
    if (signal.aborted) return null;
    const muxed = await muxClip(ffmpeg, live, partial, signal);
    live.close('motion clip capture finished');
    live = null;
    if (!muxed || !(await hasDecodableFrame(ffmpeg, partial, signal))) {
      if (signal.aborted) return null;
      throw new Error('No valid video in motion clip');
    }
    try {
      await fs.link(partial, destination);
    } catch (error) {
      if (error.code === 'EEXIST') return null;
      throw error;
    }
    return destination;
  } finally {
    live?.close('motion clip capture stopped');
    await fs.rm(partial, { force: true });
  }
}

async function startMotionRecorder({ cameras, openPreview, ffmpeg, report, watchPath, outputDir, pollIntervalMs = 250 }) {
  const incomingDir = path.join(path.dirname(outputDir), 'incoming');
  if (incomingDir === outputDir) throw new Error('The recordings directory must be separate from incoming.');
  await Promise.all([outputDir, incomingDir].map((directory) =>
    fs.mkdir(directory, { recursive: true, mode: 0o700 })
  ));
  const byHost = new Map(cameras.map((camera) => [camera.host, camera]));
  const latest = new Map();
  const active = new Map();
  const controller = new AbortController();
  const watcher = spawn('python3', ['-u', watchPath, '--events', '--interval', String(pollIntervalMs / 1000), ...byHost.keys()], {
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  const lines = createInterface({ input: watcher.stdout, crlfDelay: Infinity });
  const watchClosed = new Promise((resolve) => {
    watcher.on('error', () => report('Could not start the motion watcher.'));
    watcher.once('close', resolve);
  });
  function stop() {
    controller.abort();
    watcher.kill();
  }

  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
  lines.on('line', (line) => {
    if (controller.signal.aborted) return;
    let event;
    try { event = JSON.parse(line); } catch { return; }
    const camera = byHost.get(event?.host);
    const alarm = event?.alarm;
    if (!camera || !Number.isSafeInteger(alarm) || alarm <= 0 || alarm > 253402300799) return;
    if (alarm <= (latest.get(camera.host) ?? 0)) return;
    latest.set(camera.host, alarm);
    if (active.has(camera.host)) return;
    report(`Camera ${camera.id}: motion detected, opening video.`);
    const clip = saveClip({ camera, alarm, openPreview, ffmpeg, outputDir, incomingDir, signal: controller.signal, report })
      .then((filename) => { if (filename) report(`Camera ${camera.id}: saved ${filename}`); })
      .catch(() => {
        if (!controller.signal.aborted) report(`Camera ${camera.id}: motion clip could not be saved.`);
      })
      .finally(() => active.delete(camera.host));
    active.set(camera.host, clip);
  });
  report(`Motion recorder is watching ${byHost.size} cameras every ${pollIntervalMs} ms. Clips go to ${outputDir}`);

  try {
    const code = await watchClosed;
    if (!controller.signal.aborted) {
      throw new Error(`Motion watcher exited unexpectedly (${code ?? 'signal'})`);
    }
  } finally {
    stop();
    lines.close();
    await Promise.allSettled(active.values());
    process.off('SIGINT', stop);
    process.off('SIGTERM', stop);
    report('Motion recorder stopped.');
  }
}

module.exports = { startMotionRecorder };
