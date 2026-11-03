/** A separate process simulates OpenHarmony arm64 and observes which addon file flock selects. */
import assert from 'node:assert/strict';
import path from 'node:path';

// Workspace links resolve to packages/openharmony-arm64; installs to node-addon-system-openharmony-arm64.
const expected = path.join('openharmony-arm64', 'bin', 'system.node');
const platform = Object.getOwnPropertyDescriptor(process, 'platform');
const arch = Object.getOwnPropertyDescriptor(process, 'arch');
const originalDlopen = process.dlopen;
let opened;
try {
  Object.defineProperty(process, 'platform', { value: 'openharmony' });
  Object.defineProperty(process, 'arch', { value: 'arm64' });
  process.dlopen = (_module, filename) => {
    opened = filename;
    throw Object.assign(new Error('fixture refuses dlopen'), { code: 'FIXTURE_DLOPEN' });
  };
  const { tryLockExclusive } = await import('../../packages/entry/lib/flock.js');
  const error = await tryLockExclusive(-1).then(() => assert.fail('flock resolved without an addon'), (reason) => reason);
  // A built payload reaches dlopen; an unbuilt one fails resolution naming the selected file.
  if (error.code === 'FIXTURE_DLOPEN') {
    assert.ok(opened.endsWith(expected), opened);
  } else {
    assert.equal(error.code, 'MODULE_NOT_FOUND');
    assert.ok(error.message.includes(expected), error.message);
  }
} finally {
  process.dlopen = originalDlopen;
  Object.defineProperty(process, 'platform', platform);
  Object.defineProperty(process, 'arch', arch);
}
await new Promise((resolve, reject) => {
  process.send({ type: 'ready' }, (error) => error ? reject(error) : resolve());
});
process.disconnect();
