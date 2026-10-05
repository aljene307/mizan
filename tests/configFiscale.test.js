import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parametreEnVigueur, valeurEnVigueur } from '../src/configFiscale.js';

const config = [
  { cle: 'tva.taux_normal', valeur: '19.0000', valide_du: '2026-01-01', valide_au: '2027-01-01', a_confirmer: true },
  { cle: 'tva.taux_normal', valeur: '20.0000', valide_du: '2027-01-01', valide_au: null, a_confirmer: true },
];

test('renvoie la valeur en vigueur à la date', () => {
  assert.equal(valeurEnVigueur(config, 'tva.taux_normal', '2026-03-15'), 19);
  assert.equal(valeurEnVigueur(config, 'tva.taux_normal', '2026-12-31'), 19);
  assert.equal(valeurEnVigueur(config, 'tva.taux_normal', '2027-01-01'), 20);
});

test('lève une erreur hors période ou pour une clé inconnue', () => {
  assert.throws(() => parametreEnVigueur(config, 'tva.taux_normal', '2025-12-31'), /0 valeur/);
  assert.throws(() => parametreEnVigueur(config, 'inconnue', '2026-03-15'), /0 valeur/);
});
