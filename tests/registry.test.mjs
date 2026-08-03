import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createEngine } from './harness.mjs';

let lua;
beforeEach(async () => { lua = await createEngine(); });
afterEach(() => lua.global.close());

describe('Option validation', () => {
  const validate = (option) => lua.doString(`
    local result = NxcTarget.Options.validate(${option})
    if result.ok then return { ok = true } end
    local fields = {}
    for _, f in ipairs(result.error.details.fields) do fields[#fields + 1] = f.field end
    table.sort(fields)
    return { ok = false, fields = table.concat(fields, ',') }
  `);

  test('a minimal option validates', async () => {
    const r = await validate(`{ id='open', label='Open', global='vehicle', clientEvent='e' }`);
    assert.equal(r.ok, true);
  });

  test('an option must do something', async () => {
    const r = await validate(`{ id='open', label='Open', global='vehicle' }`);
    assert.equal(r.ok, false);
    assert.equal(r.fields, 'option');
  });

  test('an option must attach to something', async () => {
    const r = await validate(`{ id='open', label='Open', clientEvent='e' }`);
    assert.equal(r.ok, false);
    assert.equal(r.fields, 'option');
  });

  test('attaching to two kinds at once is refused', async () => {
    const r = await validate(
      `{ id='open', label='Open', clientEvent='e', global='vehicle', models={'prop_door'} }`);
    // An option that is both "every vehicle" and "this model" has no meaningful
    // answer for which distance or filters apply.
    assert.equal(r.ok, false);
    assert.equal(r.fields, 'option');
  });

  test('a label may be a function, for a label that reflects state', async () => {
    const r = await validate(
      `{ id='lock', label=function() return 'Lock' end, global='vehicle', clientEvent='e' }`);
    // "Lock" or "Unlock" on the same option. A display concern, so it is allowed
    // to be client-side.
    assert.equal(r.ok, true);
  });

  test('distance is capped', async () => {
    assert.equal((await validate(`{ id='x', label='X', global='ped', clientEvent='e', distance=2 }`)).ok, true);
    const far = await validate(`{ id='x', label='X', global='ped', clientEvent='e', distance=50 }`);
    // Further than the cap is not a target, it is a remote control — and the
    // server has to re-check distance against something.
    assert.equal(far.ok, false);
    assert.equal(far.fields, 'distance');
  });

  test('a bone needs something to belong to', async () => {
    const orphan = await validate(
      `{ id='x', label='X', global='vehicle', clientEvent='e', bones={'door_dside_f'} }`);
    // Attaching a bone to "every vehicle in the world" silently never matches.
    assert.equal(orphan.ok, false);
    assert.equal(orphan.fields, 'bones');

    const attached = await validate(
      `{ id='x', label='X', models={'adder'}, clientEvent='e', bones={'door_dside_f'} }`);
    assert.equal(attached.ok, true);
  });

  test('an unknown global kind is refused', async () => {
    const r = await validate(`{ id='x', label='X', global='helicopter', clientEvent='e' }`);
    assert.equal(r.ok, false);
    assert.equal(r.fields, 'global');
  });
});

describe('Registration and namespacing', () => {
  test('options are keyed by owner, so two resources cannot collide', async () => {
    const r = await lua.doString(`
      local reg = NxcTarget.Registry.new()
      NxcTarget.Registry.add(reg, { id='open', label='Open door', global='object', clientEvent='e' }, 'nxc_doors')
      NxcTarget.Registry.add(reg, { id='open', label='Open boot', global='vehicle', clientEvent='e' }, 'nxc_vehicles')
      return {
        count = reg.count,
        doors = NxcTarget.Registry.get(reg, 'nxc_doors:open').label,
        vehicles = NxcTarget.Registry.get(reg, 'nxc_vehicles:open').label,
      }
    `);
    // And more importantly, a resource cannot overwrite or invoke another's
    // option by guessing its id.
    assert.equal(r.count, 2);
    assert.equal(r.doors, 'Open door');
    assert.equal(r.vehicles, 'Open boot');
  });

  test('an option with no owner is refused', async () => {
    const r = await lua.doString(`
      local reg = NxcTarget.Registry.new()
      local result = NxcTarget.Registry.add(reg, { id='x', label='X', global='ped', clientEvent='e' }, nil)
      return { ok = result.ok, count = reg.count }
    `);
    assert.equal(r.ok, false);
    assert.equal(r.count, 0);
  });

  test('a resource stopping takes exactly its options', async () => {
    const r = await lua.doString(`
      local reg = NxcTarget.Registry.new()
      NxcTarget.Registry.add(reg, { id='a', label='A', global='ped', clientEvent='e' }, 'nxc_doors')
      NxcTarget.Registry.add(reg, { id='b', label='B', models={'adder'}, clientEvent='e' }, 'nxc_doors')
      NxcTarget.Registry.add(reg, { id='c', label='C', global='ped', clientEvent='e' }, 'nxc_shops')

      local removed = NxcTarget.Registry.removeOwner(reg, 'nxc_doors')
      return { removed = removed, left = reg.count,
               survivor = NxcTarget.Registry.get(reg, 'nxc_shops:c') ~= nil,
               modelIndexCleared = reg.byModel['adder'] == nil }
    `);
    // Options that outlive their owner offer players actions that dispatch to a
    // resource which is not there, and the failure is silent.
    assert.equal(r.removed, 2);
    assert.equal(r.left, 1);
    assert.equal(r.survivor, true);
    assert.equal(r.modelIndexCleared, true, 'the model index kept a dangling entry');
  });

  test('re-registering replaces without leaving an index entry behind', async () => {
    const r = await lua.doString(`
      local reg = NxcTarget.Registry.new()
      NxcTarget.Registry.add(reg, { id='a', label='A', models={'adder'}, clientEvent='e' }, 'r')
      NxcTarget.Registry.add(reg, { id='a', label='A', models={'zentorno'}, clientEvent='e' }, 'r')
      return { count = reg.count,
               oldModel = reg.byModel['adder'] == nil,
               newModel = reg.byModel['zentorno'] ~= nil }
    `);
    assert.equal(r.count, 1);
    assert.equal(r.oldModel, true, 'the old model still pointed at the replaced option');
    assert.equal(r.newModel, true);
  });
});

describe('Candidate lookup', () => {
  const FIXTURE = `
    local reg = NxcTarget.Registry.new()
    NxcTarget.Registry.add(reg, { id='ped', label='Ped', global='ped', clientEvent='e' }, 'r')
    NxcTarget.Registry.add(reg, { id='adder', label='Adder', models={'adder'}, clientEvent='e' }, 'r')
    NxcTarget.Registry.add(reg, { id='shop', label='Shop', zones={'shop'}, clientEvent='e' }, 'r')
    NxcTarget.Registry.add(reg, { id='net', label='Net', netIds={42}, clientEvent='e' }, 'r')
    local function keys(list)
      local out = {}
      for _, option in ipairs(list) do out[#out + 1] = option.key end
      return table.concat(out, ',')
    end
  `;

  test('a lookup returns only what could apply', async () => {
    const r = await lua.doString(`
      ${FIXTURE}
      return keys(NxcTarget.Registry.candidates(reg, { model = 'adder' }))
    `);
    // Narrowing from "everything registered" to "everything attached to this" is
    // the difference between a table lookup and a full scan on each frame.
    assert.equal(r, 'r:adder');
  });

  test('several attachments combine, deduplicated', async () => {
    const r = await lua.doString(`
      ${FIXTURE}
      return keys(NxcTarget.Registry.candidates(reg,
        { model = 'adder', kind = 'ped', netId = 42, zones = { shop = true } }))
    `);
    // Sorted, so the same situation always presents the same menu. An option
    // that moves between second and third place depending on hash order makes
    // muscle memory impossible.
    assert.equal(r, 'r:adder,r:net,r:ped,r:shop');
  });

  test('a lookup matching nothing returns an empty list, not nil', async () => {
    const r = await lua.doString(`
      ${FIXTURE}
      local list = NxcTarget.Registry.candidates(reg, { model = 'nothing' })
      return { isTable = type(list) == 'table', count = #list }
    `);
    assert.equal(r.isTable, true);
    assert.equal(r.count, 0);
  });

  test('an empty query returns nothing rather than everything', async () => {
    const r = await lua.doString(`
      ${FIXTURE}
      return #NxcTarget.Registry.candidates(reg, {})
    `);
    // Failing open here would offer every registered option on every raycast
    // hit, which is both a performance problem and a disclosure one.
    assert.equal(r, 0);
  });
});
