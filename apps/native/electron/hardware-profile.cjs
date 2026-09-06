const FEATURES = ['gpu_compositing', 'rasterization', 'opengl', 'webgl', 'webgl2', 'webgpu', 'video_decode', 'video_encode'];
const STATES = new Set(['enabled', 'enabled_on', 'enabled_force', 'enabled_readback', 'disabled_off', 'disabled_software', 'disabled_off_ok', 'unavailable_off', 'unavailable_software', 'unavailable_off_ok']);
function accelerationStatus(raw = {}) {
  return Object.fromEntries(FEATURES.map(key => [key, STATES.has(raw[key]) ? raw[key] : 'unknown']));
}
function chromiumSample(rows = []) {
  const gpu = rows.filter(row => row.type === 'GPU');
  return { gpuProcessCpuPercent: gpu.reduce((n, row) => n + (Number.isFinite(row.cpu?.percentCPUUsage) ? row.cpu.percentCPUUsage : 0), 0),
    gpuProcessRssMiB: gpu.reduce((n, row) => n + (Number.isFinite(row.memory?.workingSetSize) ? row.memory.workingSetSize / 1024 : 0), 0) };
}
module.exports = { accelerationStatus, chromiumSample };
