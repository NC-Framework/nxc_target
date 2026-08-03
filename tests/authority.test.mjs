import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createEngine } from './harness.mjs';

let lua;
beforeEach(async () => { lua = await createEngine(); });
afterEach(() => lua.global.close());

/**
 * RSK-17 lives here: a visible target option mistaken for an authorised one.
 *
 * These tests exist to hold down the one property the whole resource is shaped
 * around — that `applies` and `permits` are different questions with different
 * trust models, and that merging them into one convenient check would undo it.
 *
 * If someone later "simplifies" this file by having the server call `applies`,
 * these are what should stop them.
 */
describe('applies and permits are not the same question', () => {
  test('permits never calls canInteract, even when the option has one', async () => {
    const r = await lua.doString(`
      local called = false
      local option = {
        id = 'x', label = 'X', global = 'ped', serverEvent = 'e',
        canInteract = function() called = true return false end,
      }
      local permitted = NxcTarget.Filters.permits(option, { distance = 1 })
      return { called = called, ok = permitted.ok }
    `);
    // canInteract lives in a client's Lua state. Calling it server-side would be
    // asking the player whether the player is allowed.
    assert.equal(r.called, false, 'the server called a client-supplied function');
    assert.equal(r.ok, true);
  });

  test('an option hidden by canInteract is still permitted if nothing else forbids it', async () => {
    const r = await lua.doString(`
      local option = {
        id = 'x', label = 'X', global = 'ped', serverEvent = 'e',
        canInteract = function() return false end,
      }
      local shown = NxcTarget.Filters.applies(option, { distance = 1 })
      local permitted = NxcTarget.Filters.permits(option, { distance = 1 })
      return { shown = shown, permitted = permitted.ok }
    `);
    // THE CENTRAL FACT OF THIS RESOURCE, asserted rather than described. An
    // option guarded only by canInteract is guarded by the player: they simply
    // do not draw it, and can still invoke it.
    //
    // This is not a defect to be fixed here. It is the reason `capability` and
    // `item` exist and the reason the validator warns when a server event has
    // neither.
    assert.equal(r.shown, false, 'the client would not draw it');
    assert.equal(r.permitted, true, 'and the server has nothing to refuse it with');
  });

  test('a capability is refused server-side regardless of what the client showed', async () => {
    const r = await lua.doString(`
      local option = { id='x', label='X', global='ped', serverEvent='e', capability='doors.open' }
      local shown = NxcTarget.Filters.applies(option, { distance = 1, capabilities = { ['doors.open'] = true } })
      -- The client claims the capability; the server's own view does not have it.
      local permitted = NxcTarget.Filters.permits(option, { distance = 1, capabilities = {} })
      return { shown = shown, permitted = permitted.ok, code = permitted.error.code }
    `);
    assert.equal(r.shown, true);
    assert.equal(r.permitted, false);
    assert.equal(r.code, 'NXC_LIB_FORBIDDEN');
  });

  test('distance is re-measured server-side', async () => {
    const r = await lua.doString(`
      local option = { id='x', label='X', global='ped', serverEvent='e', distance = 2 }
      -- The client says it was standing next to it. The server measured 40m.
      local permitted = NxcTarget.Filters.permits(option, { distance = 40 })
      return { ok = permitted.ok, reason = permitted.error.details.reason,
               allowed = permitted.error.details.allowed }
    `);
    assert.equal(r.ok, false);
    assert.equal(r.reason, 'too_far');
    assert.equal(r.allowed, 2);
  });

  test('an unknown distance is a refusal, not a pass', async () => {
    const r = await lua.doString(`
      local option = { id='x', label='X', global='ped', serverEvent='e' }
      local permitted = NxcTarget.Filters.permits(option, {})
      return { ok = permitted.ok, reason = permitted.error.details.reason }
    `);
    // A server that could not work out where the player was must not conclude
    // they were close enough. Failing open here would make every option
    // reachable from anywhere the moment entity resolution broke.
    assert.equal(r.ok, false);
    assert.equal(r.reason, 'distance_unknown');
  });

  test('a small tolerance is allowed, and it is small', async () => {
    const r = await lua.doString(`
      local option = { id='x', label='X', global='ped', serverEvent='e', distance = 2 }
      return {
        justOver = NxcTarget.Filters.permits(option, { distance = 3.0 }).ok,
        wellOver = NxcTarget.Filters.permits(option, { distance = 4.0 }).ok,
      }
    `);
    // The client acted on a position a few frames old. Without slack, a player
    // walking away while choosing gets a refusal that reads like a bug.
    assert.equal(r.justOver, true);
    assert.equal(r.wellOver, false);
  });

  test('a canInteract that errors hides the option', async () => {
    const r = await lua.doString(`
      local option = {
        id='x', label='X', global='ped', serverEvent='e',
        canInteract = function() error('boom') end,
      }
      local shown, why = NxcTarget.Filters.applies(option, { distance = 1 })
      return { shown = shown, why = why }
    `);
    // A broken filter fails closed. Showing an option whose availability is
    // unknown is worse than hiding one that should have been available.
    assert.equal(r.shown, false);
    assert.match(r.why, /errored/);
  });
});

describe('The validator warns about unguarded server actions', () => {
  test('a server event with no capability or item is accepted, with an advisory', async () => {
    const r = await lua.doString(`
      local result = NxcTarget.Options.validate({
        id='x', label='X', global='ped', serverEvent='nxc_doors:server:open',
        canInteract = function() return true end,
      })
      return { ok = result.ok, advisory = result.value.advisory }
    `);
    // ACCEPTED, not refused. Plenty of actions are genuinely open to anyone
    // standing in front of the thing, and demanding a capability for those
    // pushes authors to invent meaningless ones.
    assert.equal(r.ok, true);
    assert.match(r.advisory, /guarded by the player/);
  });

  test('a server event with a capability draws no advisory', async () => {
    const r = await lua.doString(`
      local result = NxcTarget.Options.validate({
        id='x', label='X', global='ped', serverEvent='e', capability='doors.open' })
      return result.value.advisory == nil
    `);
    assert.equal(r, true);
  });

  test('a client-only option draws no advisory', async () => {
    const r = await lua.doString(`
      local result = NxcTarget.Options.validate({
        id='x', label='X', global='ped', clientEvent='e' })
      return result.value.advisory == nil
    `);
    // Nothing crosses to the server, so there is nothing for the server to
    // guard. Warning here would train people to ignore the warning.
    assert.equal(r, true);
  });
});
