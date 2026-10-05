import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normaliserRib, cleRib, ribValide, decomposerRib, formaterRib } from '../src/rib.js';

// Exemple du registre IBAN (ISO 13616) pour la Tunisie : TN59 1000 6035 1835 9847 8831.
const RIB_REGISTRE_IBAN = '10006035183598478831';

test('cleRib retrouve la clé de l\'exemple du registre IBAN', () => {
  assert.equal(cleRib(RIB_REGISTRE_IBAN.slice(0, 18)), '31');
});

test('cleRib renvoie toujours 2 chiffres', () => {
  for (const base of ['990010000000000001', '990010000000000123', '000000000000000000']) {
    assert.match(cleRib(base), /^\d{2}$/);
  }
  assert.throws(() => cleRib('123'), TypeError);
});

test('ribValide accepte un RIB correct, même avec espaces', () => {
  assert.ok(ribValide(RIB_REGISTRE_IBAN));
  assert.ok(ribValide('10 006 0351835984788 31'));
});

test('ribValide refuse une clé fausse, une longueur fausse ou des lettres', () => {
  assert.ok(!ribValide('10006035183598478832'));
  assert.ok(!ribValide('1000603518359847883'));
  assert.ok(!ribValide('1000603518359847883A'));
  assert.ok(!ribValide(''));
  assert.ok(!ribValide(null));
});

test('une erreur sur un seul chiffre est détectée', () => {
  for (let i = 0; i < 18; i += 1) {
    const chiffres = RIB_REGISTRE_IBAN.split('');
    chiffres[i] = String((Number(chiffres[i]) + 1) % 10);
    assert.ok(!ribValide(chiffres.join('')), `position ${i}`);
  }
});

test('normaliserRib, decomposerRib et formaterRib', () => {
  assert.equal(normaliserRib(' 10-006.0351 '), '100060351');
  assert.deepEqual(decomposerRib(RIB_REGISTRE_IBAN), {
    banque: '10', agence: '006', compte: '0351835984788', cle: '31',
  });
  assert.equal(decomposerRib('10006035183598478832'), null);
  assert.equal(formaterRib(RIB_REGISTRE_IBAN), '10 006 0351835984788 31');
});
