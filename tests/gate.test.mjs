import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createResourceEngine } from './boundary.mjs';

/**
 * The server gate, driven the way an attacker would drive it.
 *
 * The selection handler is a net event, so it cannot be called across the
 * boundary harness — that models export marshalling, not events. Instead the
 * server engine is loaded with the natives stubbed and the handler invoked
 * directly, which is exactly what a forged `TriggerServerEvent` does.
 *
 * **Every test here sends something a legitimate client would not send.** The
 * happy path is one test; the rest are the reason the file exists.
 */
describe('The server selection gate', () => {
  let lua;

  beforeEach(async () => {
    lua = await createResourceEngine('nxc_target', {
      blocks: ['shared_scripts', 'server_scripts'],
    });

    // A world the server believes in: one entity at the origin, one player 1m
    // away, and a record of what actually got dispatched.
    await lua.doString(`
      __dispatched = {}
      __entities = { [42] = { x = 0, y = 0, z = 0 } }
      __playerAt = { x = 1, y = 0, z = 0 }
      __capabilities = {}

      function NetworkGetEntityFromNetworkId(netId)
        return __entities[netId] and netId or 0
      end
      function DoesEntityExist(entity) return __entities[entity] ~= nil end
      function GetPlayerPed() return 1 end
      function GetEntityCoords(entity)
        if entity == 1 then return __playerAt end
        return __entities[entity]
      end
      function TriggerEvent(name, context)
        __dispatched[#__dispatched + 1] = { name = name, context = context }
      end

      exports = setmetatable({}, { __index = function()
        return {
          capabilities = function() return __capabilities end,
          accountFor = function() return 'acc_test' end,
          characterFor = function() return nil end,
        }
      end })

      function __select(selection, from)
        source = from or 5
        __events['nxc_target:server:select'](selection)
      end
    `);
  });

  afterEach(() => lua.global.close());

  const registerOption = (extra = '') => lua.doString(`
    __exports['register']({
      id = 'open', label = 'Open', netIds = { 42 },
      serverEvent = 'nxc_doors:server:open', distance = 3 ${extra}
    })
  `);

  test('a legitimate selection dispatches the option’s own event', async () => {
    await registerOption();
    const r = await lua.doString(`
      __select({ key = 'nxc_target:open', netId = 42 })
      return { count = #__dispatched, name = __dispatched[1] and __dispatched[1].name }
    `);
    assert.equal(r.count, 1);
    assert.equal(r.name, 'nxc_doors:server:open');
  });

  test('the client cannot name the event it wants fired', async () => {
    await registerOption();
    const r = await lua.doString(`
      __select({ key = 'nxc_target:open', netId = 42,
                 serverEvent = 'nxc_banking:server:withdrawEverything' })
      return __dispatched[1].name
    `);
    // THE CENTRAL PROTECTION. If the payload could name the event, this handler
    // would be a remote procedure call into every server event in the system,
    // addressed by string.
    assert.equal(r, 'nxc_doors:server:open');
  });

  test('an unregistered key dispatches nothing', async () => {
    const r = await lua.doString(`
      __select({ key = 'nxc_banking:withdraw', netId = 42 })
      return #__dispatched
    `);
    assert.equal(r, 0);
  });

  test('a claimed distance is ignored; the server measures its own', async () => {
    await registerOption();
    const r = await lua.doString(`
      __playerAt = { x = 500, y = 0, z = 0 }
      __select({ key = 'nxc_target:open', netId = 42, distance = 0.5 })
      return #__dispatched
    `);
    // The client says it is standing on top of the entity. The server measured
    // 500 metres.
    assert.equal(r, 0);
  });

  test('an entity the server cannot resolve is refused', async () => {
    await registerOption();
    const r = await lua.doString(`
      __select({ key = 'nxc_target:open', netId = 9999 })
      return #__dispatched
    `);
    // A netId is an index the server resolves itself, which is exactly why the
    // payload carries one rather than a coordinate.
    assert.equal(r, 0);
  });

  test('a missing capability is refused even though the client showed the option', async () => {
    await registerOption(`, capability = 'doors.open'`);
    const r = await lua.doString(`
      __capabilities = {}
      __select({ key = 'nxc_target:open', netId = 42 })
      return #__dispatched
    `);
    assert.equal(r, 0);
  });

  test('a capability the session actually holds is permitted', async () => {
    await registerOption(`, capability = 'doors.open'`);
    const r = await lua.doString(`
      __capabilities = { ['doors.open'] = true }
      __select({ key = 'nxc_target:open', netId = 42 })
      return #__dispatched
    `);
    assert.equal(r, 1);
  });

  test('a claimed capability in the payload counts for nothing', async () => {
    await registerOption(`, capability = 'doors.open'`);
    const r = await lua.doString(`
      __capabilities = {}
      __select({ key = 'nxc_target:open', netId = 42,
                 capabilities = { ['doors.open'] = true } })
      return #__dispatched
    `);
    assert.equal(r, 0);
  });

  test('an item-gated option is refused while no inventory exists', async () => {
    await registerOption(`, item = 'lockpick'`);
    const r = await lua.doString(`
      __select({ key = 'nxc_target:open', netId = 42 })
      return #__dispatched
    `);
    // nxc_inventory is Phase 3. FAILING CLOSED means the feature looks broken
    // until inventory exists, which is honest; failing open would leave every
    // item-gated action in the game ungated with nothing saying so.
    assert.equal(r, 0);
  });

  test('a registered inventory provider is consulted', async () => {
    await registerOption(`, item = 'lockpick'`);
    const r = await lua.doString(`
      __exports['setItemProvider'](function() return { lockpick = true } end)
      __select({ key = 'nxc_target:open', netId = 42 })
      local without = #__dispatched
      __exports['setItemProvider'](function() return {} end)
      __select({ key = 'nxc_target:open', netId = 42 })
      return { with = without, after = #__dispatched }
    `);
    assert.equal(r.with, 1);
    assert.equal(r.after, 1, 'a player without the item was let through');
  });

  test('malformed payloads dispatch nothing and do not throw', async () => {
    await registerOption();
    const r = await lua.doString(`
      __select(nil)
      __select('nxc_target:open')
      __select({})
      __select({ key = 42 })
      return #__dispatched
    `);
    assert.equal(r, 0);
  });

  test('the handler receives a context built from the server, not the payload', async () => {
    await registerOption();
    const r = await lua.doString(`
      __select({ key = 'nxc_target:open', netId = 42,
                 account = 'acc_someone_else', source = 999 })
      local context = __dispatched[1].context
      return { account = context.account, source = context.source,
               hasCorrelation = type(context.correlationId) == 'string' }
    `);
    // A handler reading this does not need to re-derive anything, and the
    // client's claims about who it is never reach it.
    assert.equal(r.account, 'acc_test');
    assert.equal(r.source, 5);
    assert.equal(r.hasCorrelation, true);
  });

  test('a burst from one player is rate limited', async () => {
    await registerOption();
    const r = await lua.doString(`
      for _ = 1, 20 do __select({ key = 'nxc_target:open', netId = 42 }) end
      return #__dispatched
    `);
    // A real selection is a player pressing a key while looking at something.
    // The limit exists for the case where the client is a script instead.
    assert.ok(r > 0, 'the limiter blocked everything, including the first');
    assert.ok(r < 20, `the limiter let all 20 through (${r})`);
  });

  test('the display copy sent to clients hides the event name', async () => {
    const r = await lua.doString(`
      local sent
      function TriggerClientEvent(name, target, payload) sent = payload end
      __exports['register']({
        id = 'open', label = 'Open', netIds = { 42 },
        serverEvent = 'nxc_doors:server:open',
      })
      return { hasEvent = sent.serverEvent ~= nil, hasLabel = sent.label == 'Open' }
    `);
    // A client cannot invoke an event whose name it has no way to learn, and
    // reading the option list should not enumerate the server's event surface.
    assert.equal(r.hasEvent, false);
    assert.equal(r.hasLabel, true);
  });
});
