// Host loader for graff-kernel.wasm (ADR 0012).
//
// The module is the finite kernels, not the agent. No JSPI. Flag bits
// match src/kernel_catalog.zig: no_local, lean, imagegen, clock_sleep,
// learn_loaded, is_sub.

export const FLAG = Object.freeze({
  noLocal: 1 << 0,
  lean: 1 << 1,
  imagegen: 1 << 2,
  clockSleep: 1 << 3,
  learnLoaded: 1 << 4,
  isSub: 1 << 5,
});

export function packFlags(flags = {}) {
  let bits = 0;
  if (flags.noLocal) bits |= FLAG.noLocal;
  if (flags.lean) bits |= FLAG.lean;
  if (flags.imagegen) bits |= FLAG.imagegen;
  if (flags.clockSleep) bits |= FLAG.clockSleep;
  if (flags.learnLoaded) bits |= FLAG.learnLoaded;
  if (flags.isSub) bits |= FLAG.isSub;
  return bits;
}

function decoder() {
  return new TextDecoder();
}

function encoder() {
  return new TextEncoder();
}

export async function loadGraffKernel(wasm) {
  const source =
    wasm instanceof WebAssembly.Module
      ? wasm
      : wasm instanceof ArrayBuffer || ArrayBuffer.isView(wasm)
        ? wasm
        : await (await fetch(wasm)).arrayBuffer();
  const { instance } = await WebAssembly.instantiate(source, {});
  const ex = instance.exports;
  if (ex.graff_abi_version() !== 1) {
    throw new Error(`unsupported graff-kernel ABI ${ex.graff_abi_version()}`);
  }
  return {
    instance,
    abiVersion: () => ex.graff_abi_version(),
    cubeCells: () => ex.graff_cube_cells(),
    catalog(flags = {}) {
      const n = ex.graff_catalog(packFlags(flags));
      if (n < 0) throw new Error("graff_catalog: scratch overflow");
      const mem = new Uint8Array(ex.memory.buffer);
      const ptr = ex.graff_scratch_ptr();
      return JSON.parse(decoder().decode(mem.subarray(ptr, ptr + n)));
    },
    advertised(name, flags = {}) {
      const n = writeScratch(ex, name);
      return ex.graff_advertised(packFlags(flags), n) === 1;
    },
    confined(path) {
      const n = writeScratch(ex, path);
      return ex.graff_confined(n) === 1;
    },
  };
}

function writeScratch(ex, text) {
  const bytes = encoder().encode(text);
  const cap = ex.graff_scratch_len();
  if (bytes.length > cap) throw new Error("scratch overflow");
  const mem = new Uint8Array(ex.memory.buffer);
  mem.set(bytes, ex.graff_scratch_ptr());
  return bytes.length;
}
