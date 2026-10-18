// Runs the wasm32 build of the differential checker under Node's WASI.
//   node check.mjs [fuzz-iterations]
import { readFile } from 'node:fs/promises';
import { WASI } from 'node:wasi';
import { argv } from 'node:process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const wasi = new WASI({
  version: 'preview1',
  args: ['check', '/repo/Tests/EgWalkerTests/Fixtures/conformance.json', argv[2] ?? '200'],
  preopens: { '/repo': root },
  returnOnExit: true,
});
const wasm = await WebAssembly.compile(await readFile(path.join(here, '.build/release/EgWalkerWasmCheck.wasm')));
const instance = await WebAssembly.instantiate(wasm, wasi.getImportObject());
const t0 = performance.now();
const code = wasi.start(instance);
console.log(`exit ${code} in ${((performance.now() - t0) / 1000).toFixed(1)} s`);
process.exitCode = code;
