// This file is injected via NODE_OPTIONS="--require /path/to/fingerprint-hook.js"
// It monkey-patches Node.js system APIs to return spoofed device identifiers.
// Reads from CAC_* env vars for hostname, MAC, machine-id, username, home, and OS info.
// Works on macOS, Linux, and Windows.

const os = require('os');
const fs = require('fs');
const child_process = require('child_process');
const path = require('path');

const fakeUsername = process.env.CAC_USERNAME;
const fakeHome = process.env.CAC_HOME;
const fakeShell = process.env.CAC_SHELL;
const fakeUid = Number.parseInt(process.env.CAC_UID || '', 10);
const fakeGid = Number.parseInt(process.env.CAC_GID || '', 10);
const fakeOsType = process.env.CAC_OS_TYPE;
const fakeOsRelease = process.env.CAC_OS_RELEASE;
const fakeOsVersion = process.env.CAC_OS_VERSION;
const fakeOsPrettyName = process.env.CAC_OS_PRETTY_NAME || fakeOsVersion;
const fakeDistroId = process.env.CAC_LINUX_DISTRO_ID;
const fakeDistroVersion = process.env.CAC_LINUX_DISTRO_VERSION;
const fakeProcVersion = process.env.CAC_PROC_VERSION;
const fakeCgroupText = process.env.CAC_CGROUP_TEXT;
const fakeMountinfoText = process.env.CAC_MOUNTINFO_TEXT;

if (fakeHome) process.env.HOME = fakeHome;
if (fakeUsername) {
  process.env.USER = fakeUsername;
  process.env.LOGNAME = fakeUsername;
}
if (fakeShell) process.env.SHELL = fakeShell;

// --- os.hostname() ---
const fakeHostname = process.env.CAC_HOSTNAME;
if (fakeHostname) {
  os.hostname = () => fakeHostname;
}

// --- os.type() / os.release() / os.version() / os.homedir() ---
if (fakeOsType) {
  os.type = () => fakeOsType;
}
if (fakeOsRelease) {
  os.release = () => fakeOsRelease;
}
if (fakeOsVersion && typeof os.version === 'function') {
  os.version = () => fakeOsVersion;
}
if (fakeHome) {
  os.homedir = () => fakeHome;
}

// --- process identity helpers ---
if (Number.isFinite(fakeUid)) {
  if (typeof process.getuid === 'function') {
    process.getuid = () => fakeUid;
  }
  if (typeof process.geteuid === 'function') {
    process.geteuid = () => fakeUid;
  }
}
if (Number.isFinite(fakeGid)) {
  if (typeof process.getgid === 'function') {
    process.getgid = () => fakeGid;
  }
  if (typeof process.getegid === 'function') {
    process.getegid = () => fakeGid;
  }
}

// --- os.networkInterfaces() ---
const fakeMac = process.env.CAC_MAC;
if (fakeMac) {
  const _origNetworkInterfaces = os.networkInterfaces.bind(os);
  os.networkInterfaces = () => {
    const ifaces = _origNetworkInterfaces();
    const macParts = fakeMac.split(':').map(h => parseInt(h, 16));
    let ifIdx = 0;
    for (const name of Object.keys(ifaces)) {
      for (const info of ifaces[name]) {
        if (info.mac && info.mac !== '00:00:00:00:00:00') {
          // Derive per-interface MAC: XOR last octet with interface index
          const derived = macParts.slice();
          derived[5] = (derived[5] ^ ifIdx) & 0xff;
          info.mac = derived.map(b => b.toString(16).padStart(2, '0')).join(':');
        }
      }
      ifIdx++;
    }
    return ifaces;
  };
}

// --- os.userInfo() ---
if (fakeUsername) {
  os.userInfo = (opts) => {
    const useBuffer = opts && opts.encoding === 'buffer';
    const enc = useBuffer ? (value) => Buffer.from(String(value)) : (value) => String(value);
    const info = {
      uid: Number.isFinite(fakeUid) ? fakeUid : 1000,
      gid: Number.isFinite(fakeGid) ? fakeGid : 1000,
      username: enc(fakeUsername),
      homedir: enc(fakeHome || process.env.HOME || '/home/user'),
      shell: enc(fakeShell || process.env.SHELL || '/bin/sh'),
    };
    return info;
  };
}

// --- virtual file interception helpers ---
const VIRTUAL_FILE_MAP = new Map();
const VIRTUAL_MISSING_PATHS = new Set([
  '/.dockerenv',
  '/run/.containerenv',
]);
const MACHINE_ID_PATHS = ['/etc/machine-id', '/var/lib/dbus/machine-id'];

function setVirtualFile(filePath, content) {
  if (!content) return;
  VIRTUAL_FILE_MAP.set(filePath, content.endsWith('\n') ? content : `${content}\n`);
}

function buildOsReleaseFile() {
  if (!fakeOsPrettyName && !fakeDistroId && !fakeDistroVersion) return '';
  const versionLabel = fakeDistroVersion || '';
  const fullVersion = fakeOsPrettyName || fakeOsVersion || 'Linux';
  const name = fullVersion.replace(/\s+\d.*$/, '') || 'Linux';
  const lines = [
    `PRETTY_NAME="${fullVersion}"`,
    `NAME="${name}"`,
    ...(versionLabel ? [`VERSION_ID="${versionLabel}"`, `VERSION="${versionLabel}"`] : []),
    ...(fakeDistroId ? [`ID=${fakeDistroId}`] : []),
  ];
  return `${lines.join('\n')}\n`;
}

const fakeMachineId = process.env.CAC_MACHINE_ID;
if (fakeMachineId) {
  const fakeData = `${fakeMachineId}\n`;
  for (const filePath of MACHINE_ID_PATHS) {
    VIRTUAL_FILE_MAP.set(filePath, fakeData);
  }
}

const fakeOsReleaseFile = buildOsReleaseFile();
if (fakeOsReleaseFile) {
  setVirtualFile('/etc/os-release', fakeOsReleaseFile);
  setVirtualFile('/usr/lib/os-release', fakeOsReleaseFile);
}
if (fakeProcVersion) {
  setVirtualFile('/proc/version', fakeProcVersion);
}
if (fakeOsRelease) {
  setVirtualFile('/proc/sys/kernel/osrelease', fakeOsRelease);
}
if (fakeCgroupText) {
  [
    '/proc/1/cgroup',
    '/proc/self/cgroup',
    '/proc/thread-self/cgroup',
  ].forEach(p => setVirtualFile(p, fakeCgroupText));
}
if (fakeMountinfoText) {
  [
    '/proc/1/mountinfo',
    '/proc/self/mountinfo',
    '/proc/thread-self/mountinfo',
  ].forEach(p => setVirtualFile(p, fakeMountinfoText));
}

function normalizePathValue(p) {
  if (typeof p === 'string') return p;
  if (Buffer.isBuffer(p)) return p.toString();
  if (p && typeof p === 'object' && p.href && p.protocol === 'file:') {
    try {
      return require('url').fileURLToPath(p);
    } catch (_) {
      return '';
    }
  }
  return p && p.toString ? p.toString() : '';
}

function getVirtualFile(pathValue) {
  const filePath = normalizePathValue(pathValue);
  return VIRTUAL_FILE_MAP.get(filePath) || null;
}

function isVirtualMissingPath(pathValue) {
  const filePath = normalizePathValue(pathValue);
  return VIRTUAL_MISSING_PATHS.has(filePath);
}

function fakeResult(options, data) {
  return (typeof options === 'string' || (options && options.encoding))
    ? data : Buffer.from(data);
}

// --- fs.readFileSync / fs.readFile / fs.promises.readFile ---
if (VIRTUAL_FILE_MAP.size > 0) {
  const _origReadFileSync = fs.readFileSync.bind(fs);
  fs.readFileSync = (path, options) => {
    const fakeData = getVirtualFile(path);
    if (fakeData !== null) return fakeResult(options, fakeData);
    return _origReadFileSync(path, options);
  };

  const _origReadFile = fs.readFile.bind(fs);
  fs.readFile = (path, ...args) => {
    const fakeData = getVirtualFile(path);
    if (fakeData !== null) {
      const cb = typeof args[args.length - 1] === 'function' ? args[args.length - 1] : null;
      if (cb) {
        const opts = args.length > 1 ? args[0] : null;
        process.nextTick(cb, null, fakeResult(opts, fakeData));
        return;
      }
    }
    return _origReadFile(path, ...args);
  };

  // Patch fs.promises.readFile (used by modern Node.js code)
  try {
    const fsp = require('fs').promises || require('fs/promises');
    if (fsp && fsp.readFile) {
      const _origPromiseReadFile = fsp.readFile.bind(fsp);
      fsp.readFile = (path, options) => {
        const fakeData = getVirtualFile(path);
        if (fakeData !== null) {
          return Promise.resolve(fakeResult(options, fakeData));
        }
        return _origPromiseReadFile(path, options);
      };
    }
  } catch (_) { /* fs/promises not available on older Node */ }
}

// --- fs.exists/access/stat/lstat for hidden container traces ---
{
  const notFoundError = (filePath, syscall) => {
    const err = new Error(`ENOENT: no such file or directory, ${syscall} '${filePath}'`);
    err.code = 'ENOENT';
    err.errno = -2;
    err.path = filePath;
    err.syscall = syscall;
    return err;
  };

  const _origExistsSync = fs.existsSync.bind(fs);
  fs.existsSync = (pathValue) => {
    if (isVirtualMissingPath(pathValue)) return false;
    return _origExistsSync(pathValue);
  };

  const _origAccessSync = fs.accessSync.bind(fs);
  fs.accessSync = (pathValue, mode) => {
    if (isVirtualMissingPath(pathValue)) throw notFoundError(normalizePathValue(pathValue), 'access');
    return _origAccessSync(pathValue, mode);
  };

  const _origStatSync = fs.statSync.bind(fs);
  fs.statSync = (pathValue, options) => {
    if (isVirtualMissingPath(pathValue)) throw notFoundError(normalizePathValue(pathValue), 'stat');
    return _origStatSync(pathValue, options);
  };

  const _origLstatSync = fs.lstatSync.bind(fs);
  fs.lstatSync = (pathValue, options) => {
    if (isVirtualMissingPath(pathValue)) throw notFoundError(normalizePathValue(pathValue), 'lstat');
    return _origLstatSync(pathValue, options);
  };

  const _origAccess = fs.access.bind(fs);
  fs.access = (pathValue, ...args) => {
    if (isVirtualMissingPath(pathValue)) {
      const cb = typeof args[args.length - 1] === 'function' ? args[args.length - 1] : null;
      if (cb) {
        process.nextTick(cb, notFoundError(normalizePathValue(pathValue), 'access'));
        return;
      }
    }
    return _origAccess(pathValue, ...args);
  };

  const _origStat = fs.stat.bind(fs);
  fs.stat = (pathValue, ...args) => {
    if (isVirtualMissingPath(pathValue)) {
      const cb = typeof args[args.length - 1] === 'function' ? args[args.length - 1] : null;
      if (cb) {
        process.nextTick(cb, notFoundError(normalizePathValue(pathValue), 'stat'));
        return;
      }
    }
    return _origStat(pathValue, ...args);
  };

  const _origLstat = fs.lstat.bind(fs);
  fs.lstat = (pathValue, ...args) => {
    if (isVirtualMissingPath(pathValue)) {
      const cb = typeof args[args.length - 1] === 'function' ? args[args.length - 1] : null;
      if (cb) {
        process.nextTick(cb, notFoundError(normalizePathValue(pathValue), 'lstat'));
        return;
      }
    }
    return _origLstat(pathValue, ...args);
  };

  try {
    const fsp = require('fs').promises || require('fs/promises');
    if (fsp) {
      const _origAccessPromise = fsp.access?.bind(fsp);
      if (_origAccessPromise) {
        fsp.access = (pathValue, mode) => {
          if (isVirtualMissingPath(pathValue)) return Promise.reject(notFoundError(normalizePathValue(pathValue), 'access'));
          return _origAccessPromise(pathValue, mode);
        };
      }
      const _origStatPromise = fsp.stat?.bind(fsp);
      if (_origStatPromise) {
        fsp.stat = (pathValue, options) => {
          if (isVirtualMissingPath(pathValue)) return Promise.reject(notFoundError(normalizePathValue(pathValue), 'stat'));
          return _origStatPromise(pathValue, options);
        };
      }
      const _origLstatPromise = fsp.lstat?.bind(fsp);
      if (_origLstatPromise) {
        fsp.lstat = (pathValue, options) => {
          if (isVirtualMissingPath(pathValue)) return Promise.reject(notFoundError(normalizePathValue(pathValue), 'lstat'));
          return _origLstatPromise(pathValue, options);
        };
      }
    }
  } catch (_) { /* older runtimes */ }
}

// --- Windows: intercept child_process for wmic / reg queries ---
function makeFakeChildProcess() {
  const { EventEmitter } = require('events');
  const cp = new EventEmitter();
  cp.stdout = new EventEmitter();
  cp.stderr = new EventEmitter();
  cp.stdin = null;
  cp.stdio = [null, cp.stdout, cp.stderr];
  cp.pid = 0;
  cp.exitCode = null;
  cp.signalCode = null;
  cp.killed = false;
  cp.spawnargs = [];
  cp.spawnfile = '';
  cp.kill = () => false;
  return cp;
}

if (process.platform === 'win32' && fakeMachineId) {
  const _origExecSync = child_process.execSync.bind(child_process);
  child_process.execSync = (cmd, options) => {
    const cmdStr = typeof cmd === 'string' ? cmd : cmd.toString();
    if (/wmic\s+csproduct\s+get\s+uuid/i.test(cmdStr)) {
      return fakeResult(options, `UUID\n${fakeMachineId}\n`);
    }
    if (/reg\s+query.*MachineGuid/i.test(cmdStr)) {
      return fakeResult(options, `    MachineGuid    REG_SZ    ${fakeMachineId}\n`);
    }
    return _origExecSync(cmd, options);
  };

  const _origExec = child_process.exec.bind(child_process);
  child_process.exec = (cmd, ...args) => {
    const cmdStr = typeof cmd === 'string' ? cmd : cmd.toString();
    const cb = typeof args[args.length - 1] === 'function' ? args[args.length - 1] : null;
    if (/wmic\s+csproduct\s+get\s+uuid/i.test(cmdStr)) {
      if (cb) process.nextTick(cb, null, `UUID\n${fakeMachineId}\n`, '');
      return makeFakeChildProcess();
    }
    if (/reg\s+query.*MachineGuid/i.test(cmdStr)) {
      if (cb) process.nextTick(cb, null, `    MachineGuid    REG_SZ    ${fakeMachineId}\n`, '');
      return makeFakeChildProcess();
    }
    return _origExec(cmd, ...args);
  };

  const _origExecFileSync = child_process.execFileSync.bind(child_process);
  child_process.execFileSync = (file, argsOrOpts, options) => {
    // Handle optional args parameter: execFileSync(file[, args][, options])
    let args = argsOrOpts;
    let opts = options;
    if (!Array.isArray(argsOrOpts) && typeof argsOrOpts === 'object') {
      args = [];
      opts = argsOrOpts;
    }
    const fileStr = (typeof file === 'string' ? file : '').toLowerCase();
    const argsStr = Array.isArray(args) ? args.join(' ') : '';
    if ((fileStr.includes('wmic') && /csproduct.*uuid/i.test(argsStr)) ||
        (fileStr.includes('reg') && /MachineGuid/i.test(argsStr))) {
      return fakeResult(opts, fakeMachineId + '\n');
    }
    return _origExecFileSync(file, argsOrOpts, options);
  };
}
