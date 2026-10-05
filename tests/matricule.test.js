import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normaliserMatricule, formeCourteMatricule, matriculeFormatValide } from '../src/matricule.js';

test('forme courte officielle : 7 chiffres + 1 lettre', () => {
  assert.equal(formeCourteMatricule('9912345K'), '9912345K');
  assert.equal(formeCourteMatricule('0001238L'), '0001238L'); // exemple du cahier des charges TEJ
});

test('forme complète, avec ou sans barres obliques et espaces', () => {
  assert.equal(formeCourteMatricule('9912345K/A/M/000'), '9912345K');
  assert.equal(formeCourteMatricule('9912345KAM000'), '9912345K');
  assert.equal(formeCourteMatricule(' 9912345k / a / m / 001 '), '9912345K');
});

test('formats refusés', () => {
  for (const faux of ['991234K/A/M/000', '9912345/A/M/000', '99123456K', '9912345K/A/M/00', 'ABCDEFGH', '', null]) {
    assert.equal(matriculeFormatValide(faux), false, String(faux));
  }
});

test('normaliserMatricule', () => {
  assert.equal(normaliserMatricule(' 9912 345k '), '9912345K');
});
