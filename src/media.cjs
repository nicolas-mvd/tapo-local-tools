'use strict';

const { createHash, createHmac, hkdfSync, randomBytes, randomUUID, timingSafeEqual } = require('node:crypto');
const { Socket } = require('node:net');
const {
  CLIENT_BOUNDARY,
  DevicePartParser,
  TapoMediaSession,
  deriveMediaKeys,
  parseAuthHeader,
  parseBoundary,
  parseKeyValueList,
} = require('homebridge-tapo-direct/dist/tapo/mediaSession.js');
const { MediaSessionError, TapoAuthError } = require('homebridge-tapo-direct/dist/util/errors.js');

const noop = () => {};
const quietLog = { debug: noop, info: noop, warn: noop, error: noop };

function hash(algorithm, text) {
  return createHash(algorithm).update(text, 'utf8').digest('hex');
}

function digestAuthorization(auth, username, hashedCredential, uri) {
  const advertised = (auth.algorithm ?? 'MD5').toUpperCase();
  if (advertised !== 'SHA-256' && advertised !== 'MD5') {
    throw new MediaSessionError('Camera advertised an unsupported Digest algorithm');
  }
  const algorithm = advertised === 'SHA-256' ? 'sha256' : 'md5';
  const qop = (auth.qop ?? '').split(',').map((entry) => entry.trim());
  if (auth.qop && !qop.includes('auth')) {
    throw new MediaSessionError('Camera did not advertise Digest auth mode');
  }
  const nc = '00000001';
  const cnonce = randomBytes(8).toString('hex');
  const ha1 = hash(algorithm, [username, auth.realm, hashedCredential].join(':'));
  const ha2 = hash(algorithm, 'POST:' + uri);
  const response = auth.qop
    ? hash(algorithm, [ha1, auth.nonce, nc, cnonce, 'auth', ha2].join(':'))
    : hash(algorithm, [ha1, auth.nonce, ha2].join(':'));
  const userHash = auth.userhash === 'true';
  const user = userHash ? hash(algorithm, username + ':' + auth.realm) : username;
  const fields = [
    'username=' + JSON.stringify(user),
    'realm=' + JSON.stringify(auth.realm),
    'uri=' + JSON.stringify(uri),
    'algorithm=' + advertised,
    'nonce=' + JSON.stringify(auth.nonce),
    'response=' + JSON.stringify(response),
  ];
  if (auth.qop) fields.push('qop=auth', 'nc=' + nc, 'cnonce=' + JSON.stringify(cnonce));
  if (auth.opaque !== undefined) fields.push('opaque=' + JSON.stringify(auth.opaque));
  if (userHash) fields.push('userhash=true');
  return 'Digest ' + fields.join(',');
}

function keyFor(exchange, credential, usage) {
  return Buffer.from(hkdfSync(
    'sha256', Buffer.from(exchange.nonce + ':' + credential), Buffer.from(exchange.salt),
    Buffer.from('stream_hkdf_' + usage + '_key'), 16,
  ));
}

class Sha256MediaSession extends TapoMediaSession {
  static async open(options) {
    const session = new Sha256MediaSession({ ...options, log: { ...quietLog, ...options.log } });
    await session.connect();
    return session;
  }

  async connect() {
    let timer;
    const deadline = new Promise((_, reject) => {
      timer = setTimeout(() => reject(new MediaSessionError('Media handshake timed out')), this.connectTimeoutMs);
    });
    try {
      await Promise.race([this.handshake(), deadline]);
    } catch (error) {
      this._closed = true;
      this.headWaiter = undefined;
      this.socket?.destroy();
      throw error;
    } finally {
      clearTimeout(timer);
    }
  }

  async openSocket() {
    if (this._closed) throw new MediaSessionError('Media session closed');
    const previous = this.socket;
    const socket = new Socket();
    this.socket = socket;
    this.headBuf = Buffer.alloc(0);
    previous?.destroy();
    socket.setNoDelay(true);
    socket.on('data', (data) => {
      if (this.socket === socket) this.onData(data);
    });
    socket.on('error', (error) => {
      if (this.socket === socket) this.onSocketError(error);
    });
    socket.on('close', () => {
      if (this.socket === socket) this.onSocketClose();
    });
    await new Promise((resolve, reject) => {
      const fail = () => reject(new MediaSessionError('Could not connect to camera media port'));
      socket.once('error', fail);
      socket.once('close', fail);
      socket.connect(this.port, this.host, () => {
        socket.off('error', fail);
        socket.off('close', fail);
        resolve();
      });
    });
  }

  async handshake() {
    const credential = this.opts.credential ?? this.opts.cloudPassword;
    if (typeof credential !== 'string' || !credential) {
      throw new MediaSessionError('No owner credential supplied');
    }
    await this.openSocket();
    const uri = '/stream' + this.queryString;
    const requestLine = 'POST ' + uri + ' HTTP/1.1';
    const headers = [
      ['Content-Type', 'multipart/mixed; boundary=' + CLIENT_BOUNDARY],
      ['User-Agent', 'Tapo LAN viewer'],
      ['Host', this.host + ':' + this.port],
      ['Connection', 'Keep-Alive'],
      ['Accept-Encoding', 'gzip'],
      ['Content-Length', '0'],
      ['X-Key-Exchange', '1'],
      ['X-Client-UUID', this.opts.query?.playerId ?? randomUUID()],
    ];
    if (this.opts.preconnect) headers.push(['X-Preconn', '1']);
    this.writeHttpRequest(requestLine, headers);
    const challenge = await this.readHead();
    const { scheme, params: auth } = parseAuthHeader(challenge.lower['www-authenticate'] ?? '');
    if (challenge.status !== 401 || scheme.toLowerCase() !== 'digest' || !auth.realm || !auth.nonce) {
      throw new MediaSessionError('Camera did not return a valid Digest challenge');
    }
    this._encryptionMethod = auth.encrypt_type === '3' ? 'sha256' : 'md5';
    const hashedCredential = hash(this._encryptionMethod, credential).toUpperCase();
    const authorization = digestAuthorization(auth, this.username, hashedCredential, uri);
    const connection = (challenge.lower.connection ?? '').toLowerCase();
    if (connection.includes('close') || this.socket.destroyed || (
      challenge.statusLine.startsWith('HTTP/1.0') && !connection.includes('keep-alive')
    ) || Number(challenge.lower['content-length'] ?? 0) > 0) {
      await this.openSocket();
    }
    this.writeHttpRequest(requestLine, [...headers, ['Authorization', authorization]]);
    const response = await this.readHead();
    if (response.status === 401) {
      throw new TapoAuthError('The media port (8800) rejected the Digest authentication');
    }
    if (response.status !== 200) {
      throw new MediaSessionError('Camera declined the media handshake (HTTP ' + response.status + ')');
    }
    const exchange = parseKeyValueList(response.lower['key-exchange'] ?? '');
    const exchangeUser = exchange.username ?? this.username;
    if (!exchange.nonce || exchangeUser !== this.username) {
      throw new MediaSessionError('Camera did not return an owner media key exchange');
    }
    if ((exchange.algorithm ?? 'MD5').toUpperCase() === 'HKDF') {
      if (!exchange.salt) throw new MediaSessionError('Camera omitted the media key salt');
      this.aesKey = keyFor(exchange, hashedCredential, 'aes');
      this.hmacKey = keyFor(exchange, hashedCredential, 'hmac');
    } else {
      const keys = deriveMediaKeys(exchangeUser, exchange.nonce, hashedCredential, this.superSecretKey);
      this.aesKey = keys.key;
      this.aesIv = keys.iv;
    }
    this._deviceBoundary = parseBoundary(response.lower['content-type']) ?? this._deviceBoundary;
    this.parser = new DevicePartParser(
      this._deviceBoundary, (part) => this.handlePart(part), (error) => this.emitError(error),
    );
    this.started = true;
    const leftover = this.headBuf;
    this.headBuf = Buffer.alloc(0);
    if (leftover.length) this.parser.push(leftover);
  }

  handlePart(raw) {
    if (!this.hmacKey) return super.handlePart(raw);
    const nonce = raw.lower['x-nonce'];
    if (nonce !== undefined) {
      if (!/^[0-9a-f]{32}$/i.test(nonce)) return this.failMediaIntegrity('Invalid media IV');
      this.aesIv = Buffer.from(nonce, 'hex');
    }
    const encrypted = Number.parseInt(raw.lower['x-if-encrypt'] ?? '0', 10) > 0;
    if (encrypted) {
      if (this.aesIv.length !== 16) return this.failMediaIntegrity('Camera omitted the media IV');
      const tag = raw.lower['x-data-hmac'];
      if (tag !== undefined) {
        const expected = Buffer.from(createHmac('sha256', this.hmacKey).update(raw.body).digest('base64'));
        const actual = Buffer.from(tag);
        if (expected.length !== actual.length || !timingSafeEqual(expected, actual)) {
          return this.failMediaIntegrity('Media integrity check failed');
        }
      }
    }
    return super.handlePart(raw);
  }

  failMediaIntegrity(message) {
    this.emitError(new MediaSessionError(message));
    this.close();
  }
}

module.exports = { Sha256MediaSession };
