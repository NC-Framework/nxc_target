import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createBoundary } from './boundary.mjs';

/**
 * nxc_target's exports, called from another Lua state with `os` absent.
 *
 * The server exports and the client exports are separate boundaries because
 * they are separate Lua states on separate machines, and `register` means
 * something different on each side — which is the whole point of the split.
 */
describe('nxc_target server exports', () => {
  let boundary;
  beforeEach(async () => {
    boundary = await createBoundary({ provider: 'nxc_target', consumer: 'nxc_core' });
  });
  afterEach(() => boundary.close());

  test('register returns a readable Result and attributes the owner', async () => {
    const result = await boundary.callExport('register', [
      { id: 'open', label: 'Open', global: 'object', serverEvent: 'nxc_doors:server:open' },
    ], { from: 'nxc_doors' });
    assert.ok('ok' in result, 'the Result crossed as an empty table');
    assert.equal(result.ok, true);
    // Namespaced by the CALLING resource, so no resource can register into
    // another's namespace or invoke its options by guessing an id.
    assert.equal(result.value.key, 'nxc_doors:open');
  });

  test('a refusal keeps its reason across the boundary', async () => {
    const result = await boundary.callExport('register', [
      { id: 'open', label: 'Open', global: 'object' },
    ], { from: 'nxc_doors' });
    assert.equal(result.ok, false);
    assert.equal(result.error.code, 'NXC_LIB_VALIDATION_FAILED');
  });

  test('an unguarded server action is accepted with an advisory', async () => {
    const result = await boundary.callExport('register', [
      { id: 'open', label: 'Open', global: 'object', serverEvent: 'e' },
    ], { from: 'nxc_doors' });
    // Accepted, because plenty of actions are genuinely open. Reported, because
    // an author who meant to restrict it has no other way to find out.
    assert.equal(result.ok, true);
    assert.match(result.value.advisory, /guarded by the player/);
  });

  test('remove crosses as a boolean', async () => {
    await boundary.callExport('register', [
      { id: 'open', label: 'Open', global: 'object', serverEvent: 'e' },
    ], { from: 'nxc_doors' });
    assert.equal(await boundary.callExport('remove', ['nxc_doors:open']), true);
    assert.equal(await boundary.callExport('remove', ['nxc_doors:open']), false);
  });
});

describe('nxc_target client exports', () => {
  let boundary;
  beforeEach(async () => {
    boundary = await createBoundary({
      provider: 'nxc_target', consumer: 'nxc_core',
      server: false, realClock: true,
      blocks: ['shared_scripts', 'client_scripts'],
    });
  });
  afterEach(() => boundary.close());

  test('a client registration carrying a server action is refused', async () => {
    const result = await boundary.callExport('register', [
      { id: 'open', label: 'Open', global: 'object', serverEvent: 'nxc_doors:server:open' },
    ], { from: 'nxc_doors' });
    // THE SERVER DISPATCHES FROM ITS OWN REGISTRY, so a serverEvent declared
    // client-side would never run. Accepting it silently would let an author
    // believe they had built a server-checked action when they had built
    // nothing at all.
    assert.equal(result.ok, false);
    assert.match(result.error.details.fields[0].reason, /on the SERVER/);
  });

  test('a client-side option registers normally', async () => {
    const result = await boundary.callExport('register', [
      { id: 'inspect', label: 'Inspect', global: 'object', clientEvent: 'nxc_doors:client:inspect' },
    ], { from: 'nxc_doors' });
    assert.equal(result.ok, true);
  });

  test('isActive crosses as a boolean', async () => {
    assert.equal(typeof (await boundary.callExport('isActive')), 'boolean');
  });

  test('the client half loads with no os', async () => {
    const r = await boundary.provider.doString(`return type(os) .. ',' .. type(io)`);
    assert.equal(r, 'nil,nil');
  });
});
