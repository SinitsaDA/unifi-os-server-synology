'use strict'
//
// Minimal "UOS Server Manager" for UniFi OS Server running in Docker.
//
// The official installer runs a manager on the host that connects to UniFi OS
// (wss://<container>:11084/api/ws/supervisor, UCP4 protocol) and handles its requests:
// firmware updates, resources, ports. Without it "Update" in the UniFi OS console fails with
// "No connection to UOS Server Manager". This service plays that role: it answers the requests and
// turns "Update" into an update request (/uos/boot/uos-update.json) that update.sh carries out by
// switching the container to the image with the requested version.

const fs = require('fs')
const os = require('os')
const zlib = require('zlib')
const crypto = require('crypto')
const { execFile } = require('child_process')
const WebSocket = require('ws')

const CONTAINER = process.env.UOS_CONTAINER || 'unifi-os-server'
const URL = process.env.SUPERVISOR_URL || `wss://${CONTAINER}:11084/api/ws/supervisor`
const WEB_PORT = Number(process.env.UOS_WEB_PORT || 11443)
const REQUEST_FILE = process.env.UPDATE_REQUEST_FILE || '/uos/boot/uos-update.json'
const DATA_DIR = '/uos/data'
const RECONNECT_MS = 15000

const log = (...args) => console.log(new Date().toISOString().replace('T', ' ').slice(0, 19), '[supervisor]', ...args)

// ---------- binme framing: [type][format][compressed][reserved][length u32 BE][payload] x2 ----------

const TYPE_HEADER = 1
const TYPE_BODY = 2
const FORMAT_JSON = 1
const FORMAT_STRING = 2
const FORMAT_BINARY = 3

function encodePart (type, data) {
  let format, payload
  if (Buffer.isBuffer(data)) { format = FORMAT_BINARY; payload = data } else if (typeof data === 'string') { format = FORMAT_STRING; payload = Buffer.from(data) } else { format = FORMAT_JSON; payload = Buffer.from(JSON.stringify(data)) }
  const head = Buffer.alloc(8)
  head.writeUInt8(type, 0)
  head.writeUInt8(format, 1)
  head.writeUInt8(0, 2)
  head.writeUInt8(0, 3)
  head.writeUInt32BE(payload.length, 4)
  return Buffer.concat([head, payload])
}

function encode (header, body) {
  return Buffer.concat([encodePart(TYPE_HEADER, header), encodePart(TYPE_BODY, body)])
}

function decodePart (buf, offset) {
  const format = buf.readUInt8(offset + 1)
  const compressed = buf.readUInt8(offset + 2) === 1
  const length = buf.readUInt32BE(offset + 4)
  let payload = buf.subarray(offset + 8, offset + 8 + length)
  if (compressed) payload = zlib.inflateSync(payload)
  let value = payload
  if (format === FORMAT_JSON) value = payload.length ? JSON.parse(payload.toString('utf8')) : null
  else if (format === FORMAT_STRING) value = payload.toString('utf8')
  return { value, next: offset + 8 + length }
}

function decode (buf) {
  const header = decodePart(buf, 0)
  const body = header.next < buf.length ? decodePart(buf, header.next).value : null
  return { header: header.value, body }
}

// ---------- helpers ----------

function dockerExec (args) {
  return new Promise((resolve, reject) => {
    execFile('docker', ['exec', CONTAINER, ...args], { timeout: 15000 }, (err, stdout) => err ? reject(err) : resolve(stdout.trim()))
  })
}

function resources () {
  const cpus = os.cpus().length
  const ramMb = Math.floor(os.totalmem() / 1024 / 1024)
  let storageGb = 0
  try {
    const st = fs.statfsSync(DATA_DIR)
    storageGb = Math.floor((st.blocks * st.bsize) / 1024 ** 3)
  } catch (_) {}
  return {
    cpus: { min: 1, max: cpus, current: cpus },
    ramMb: { min: Math.min(4096, ramMb), max: ramMb, current: ramMb },
    storageGb: { min: Math.min(20, storageGb), max: storageGb, current: storageGb }
  }
}

const NOT_SUPPORTED = 'Not supported in the Docker version: change it in compose.yaml / .env'

const handlers = {
  firmwareUpdateToken: () => ({}),
  firmwareReleaseChannel: () => ({}),
  getPorts: () => ({ webPort: WEB_PORT }),
  getResources: () => resources(),
  setPorts: () => { throw new Error(NOT_SUPPORTED) },
  setResources: () => { throw new Error(NOT_SUPPORTED) },
  hasLegacyNet: () => ({ hasLegacyNet: false }),
  legacyNetBackup: () => ({ backupCreated: false, error: NOT_SUPPORTED }),
  exportSupportData: () => ({}),
  firmwareUpdate: (body) => {
    const version = String(body && body.version || '').replace(/^v/, '')
    if (!/^\d+(\.\d+)+$/.test(version)) throw new Error(`Invalid firmware version: ${body && body.version}`)
    const request = { version, requestedAt: new Date().toISOString(), firmware: body }
    fs.writeFileSync(`${REQUEST_FILE}.tmp`, JSON.stringify(request, null, 2))
    fs.renameSync(`${REQUEST_FILE}.tmp`, REQUEST_FILE)
    log(`Update to UniFi OS Server ${version} requested from the console`)
    return {}
  }
}

// ---------- connection ----------

function send (ws, header, body) {
  ws.send(encode({ ...header, timestamp: Date.now() }, body))
}

async function handle (ws, msg) {
  const { header, body } = msg
  if (!header) return
  if (header.type === 'event') return
  if (header.type !== 'request') {
    if (['cmd', 'httpRequest'].includes(header.type)) {
      send(ws, { id: header.id, type: 'error', errorCode: 1002, error: `No handlers for ${header.type}.${header.id}` }, '')
    }
    return
  }
  const handler = handlers[header.action]
  try {
    if (!handler) throw new Error(`Unknown action: ${header.action}`)
    const result = await handler(body)
    send(ws, { id: header.id, type: 'response', error: null, errorCode: 0 }, result ?? {})
  } catch (err) {
    log(`Request "${header.action}" failed: ${err.message}`)
    send(ws, { id: header.id, type: 'response', error: err.message, errorCode: 1 }, {})
  }
}

async function connect () {
  let token
  try {
    token = await dockerExec(['curl', '-fsS', '--max-time', '10', 'http://127.0.0.1:11081/api/supervisor/token'])
  } catch (_) {
    return setTimeout(connect, RECONNECT_MS)
  }
  if (!/^[0-9a-f-]{36}$/i.test(token)) return setTimeout(connect, RECONNECT_MS)

  const ws = new WebSocket(URL, { headers: { Authorization: `Bearer ${token}` }, rejectUnauthorized: false, handshakeTimeout: 15000 })
  let opened = false

  ws.on('open', () => { opened = true; log('Connected to UniFi OS') })
  ws.on('message', (data) => {
    try {
      handle(ws, decode(Buffer.isBuffer(data) ? data : Buffer.from(data))).catch(err => log('Handler error:', err.message))
    } catch (err) {
      log('Invalid message:', err.message)
    }
  })
  ws.on('error', (err) => { if (!opened) return; log('Connection error:', err.message) })
  ws.on('close', () => {
    if (opened) log('Disconnected from UniFi OS, reconnecting')
    setTimeout(connect, RECONNECT_MS)
  })
}

process.on('SIGTERM', () => process.exit(0))
process.on('SIGINT', () => process.exit(0))
crypto.randomUUID() // fail early on very old Node versions
log(`Starting, UniFi OS at ${URL}`)
connect()
