import { test } from 'node:test';
import assert from 'node:assert/strict';
import { newCanary, findLeaks } from './canary.mjs';

test('canaries are labelled and unique', () => {
  const a = newCanary('entity');
  assert.match(a, /^CANARY-entity-[0-9a-f]{16}$/);
  assert.notEqual(a, newCanary('entity'));
});

test('findLeaks returns labels, never values', () => {
  const entity = newCanary('entity');
  const leaks = findLeaks([`prefix ${entity} suffix`], [entity, newCanary('query')]);
  assert.deepEqual(leaks, ['entity']);
});

test('findLeaks searches nested objects including header maps', () => {
  const key = newCanary('permanent_key');
  assert.deepEqual(findLeaks([{ headers: { 'x-debug': key } }], [key]), ['permanent_key']);
});

test('findLeaks ignores empty haystacks', () => {
  assert.deepEqual(findLeaks([null, '', undefined], [newCanary('entity')]), []);
});

test('findLeaks reports each label once', () => {
  const entity = newCanary('entity');
  assert.deepEqual(findLeaks([entity, entity], [entity]), ['entity']);
});
