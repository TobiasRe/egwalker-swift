// Loads the egwalker-swift WebAssembly build and wraps its exported C functions.
//
// The Wasm module is the real Swift library (see ../Sources/EgWalkerWasm), built as
// a WASI "reactor". It only needs a handful of WASI functions, provided by the
// minimal shim below: no files, no environment, stdout/stderr go to the console.
//
// Positions are Unicode scalar offsets, the unit egwalker-swift uses. In
// JavaScript, `Array.from(string)` splits a string into exactly those units.

const ESUCCESS = 0, EBADF = 8, ENOSYS = 52;

function wasiShim(getMemory) {
  const view = () => new DataView(getMemory().buffer);
  const bytes = () => new Uint8Array(getMemory().buffer);
  const pending = { 1: '', 2: '' };
  const decoder = new TextDecoder();
  class Exit extends Error { constructor(code) { super(`exit ${code}`); this.code = code; } }
  return {
    args_sizes_get(argc, bufSize) { view().setUint32(argc, 0, true); view().setUint32(bufSize, 0, true); return ESUCCESS; },
    args_get() { return ESUCCESS; },
    environ_sizes_get(count, bufSize) { view().setUint32(count, 0, true); view().setUint32(bufSize, 0, true); return ESUCCESS; },
    environ_get() { return ESUCCESS; },
    fd_write(fd, iovs, iovsLen, nwritten) {
      let total = 0;
      for (let i = 0; i < iovsLen; i++) {
        const ptr = view().getUint32(iovs + i * 8, true);
        const len = view().getUint32(iovs + i * 8 + 4, true);
        if (fd === 1 || fd === 2) pending[fd] += decoder.decode(bytes().slice(ptr, ptr + len));
        total += len;
      }
      for (const f of [1, 2]) {
        const lines = pending[f].split('\n');
        pending[f] = lines.pop();
        for (const line of lines) (f === 2 ? console.error : console.log)(`[swift] ${line}`);
      }
      view().setUint32(nwritten, total, true);
      return ESUCCESS;
    },
    fd_read() { return EBADF; },
    fd_close() { return ESUCCESS; },
    fd_seek() { return EBADF; },
    fd_fdstat_get(fd, stat) {
      if (fd > 2) return EBADF;
      const v = view();
      v.setUint8(stat, 2); // character device
      for (let i = 1; i < 24; i++) v.setUint8(stat + i, 0);
      return ESUCCESS;
    },
    fd_prestat_get() { return EBADF; },       // no preopened directories
    fd_prestat_dir_name() { return EBADF; },
    path_open() { return ENOSYS; },
    random_get(buf, len) { crypto.getRandomValues(bytes().subarray(buf, buf + len)); return ESUCCESS; },
    clock_time_get(_id, _precision, out) { view().setBigUint64(out, BigInt(Math.round(performance.now() * 1e6)), true); return ESUCCESS; },
    clock_res_get(_id, out) { view().setBigUint64(out, 1000n, true); return ESUCCESS; },
    proc_exit(code) { throw new Exit(code); },
  };
}

export async function loadEngine(url) {
  let memory;
  const wasi = wasiShim(() => memory);
  const imports = {
    wasi_snapshot_preview1: new Proxy(wasi, {
      // Any WASI function the shim doesn't implement reports "not supported".
      get: (target, name) => target[name] ?? (() => ENOSYS),
    }),
  };
  const t0 = performance.now();
  let instance;
  if (typeof url === 'string' || url instanceof URL) {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`Could not load ${url} (HTTP ${response.status})`);
    const buffer = await response.arrayBuffer();
    ({ instance } = await WebAssembly.instantiate(buffer, imports));
  } else {
    ({ instance } = await WebAssembly.instantiate(url, imports)); // raw bytes (Node)
  }
  const ex = instance.exports;
  memory = ex.memory;
  ex._initialize();
  const loadMs = performance.now() - t0;

  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  function withString(s, fn) {
    const data = encoder.encode(s);
    const ptr = ex.eg_alloc(data.length);
    new Uint8Array(memory.buffer, ptr, data.length).set(data);
    try { return fn(ptr, data.length); } finally { ex.eg_free(ptr); }
  }
  function readResult(ptr) {
    const len = ex.eg_result_len();
    return decoder.decode(new Uint8Array(memory.buffer, ptr, len));
  }

  return {
    loadMs,
    reset(agents) { withString(agents.join(','), (p, n) => ex.eg_reset(p, n)); },
    insert(replica, pos, text) { if (text) withString(text, (p, n) => ex.eg_insert(replica, pos, p, n)); },
    delete(replica, pos, len) { if (len > 0) ex.eg_delete(replica, pos, len); },
    /** `dst` learns everything `src` knows. Returns the number of new events. */
    merge(dst, src) { return ex.eg_merge(dst, src); },
    eventCount(replica) { return ex.eg_event_count(replica); },
    /** Replays the replica's history into text (`OpLog.checkout()`). */
    text(replica) { return readResult(ex.eg_text(replica)); },
    /** Replays the replica's history: text, walker statistics and recent event runs. */
    state(replica, maxRuns = 80) { return JSON.parse(readResult(ex.eg_state(replica, maxRuns))); },
  };
}

/** Turns an edit from `before` to `after` into one delete plus one insert, in scalars. */
export function diffScalars(before, after) {
  const a = Array.from(before), b = Array.from(after);
  let start = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) start++;
  let endA = a.length, endB = b.length;
  while (endA > start && endB > start && a[endA - 1] === b[endB - 1]) { endA--; endB--; }
  return { pos: start, deleteCount: endA - start, insert: b.slice(start, endB).join('') };
}
