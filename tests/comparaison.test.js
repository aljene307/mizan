import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { CHAMPS_ENTETE, normaliserTexte, comparerValeur, comparerExtraction } from '../src/comparaison.js';

const verite = JSON.parse(readFileSync('data/synthetic/dev/verite/D007.json', 'utf8')).extraction;

test('nombres : égalité numérique, sans tolérance d\'arrondi', () => {
  assert.deepEqual(comparerValeur('nombre', 19.0, 19), { strict: true, normalise: true });
  assert.deepEqual(comparerValeur('nombre', 2755.6, 2755.601), { strict: false, normalise: false });
  assert.deepEqual(comparerValeur('nombre', '2755.6', 2755.6), { strict: false, normalise: false }, 'un texte n\'est pas un nombre');
});

test('identifiants, dates, codes : caractère pour caractère, même en normalisé', () => {
  assert.deepEqual(comparerValeur('identifiant', 'fa-2026-001', 'FA-2026-001'), { strict: false, normalise: false });
  assert.deepEqual(comparerValeur('identifiant', 'FA-2026-001 ', 'FA-2026-001'), { strict: false, normalise: false });
  assert.deepEqual(comparerValeur('date', '2026-03-01', '2026-03-01'), { strict: true, normalise: true });
  assert.deepEqual(comparerValeur('code', 'TND', 'TND'), { strict: true, normalise: true });
});

test('noms, adresses, désignations : casse et espaces multiples ignorés en normalisé, accents conservés', () => {
  assert.deepEqual(comparerValeur('texte', 'OASIS GARDIENNAGE ET SÉCURITÉ', 'Oasis Gardiennage et Sécurité'), { strict: false, normalise: true });
  assert.deepEqual(comparerValeur('texte', '  Trans-Cap   Logistique ', 'Trans-Cap Logistique'), { strict: false, normalise: true });
  assert.deepEqual(comparerValeur('texte', 'Securite', 'Sécurité'), { strict: false, normalise: false });
  assert.equal(normaliserTexte('ÉLECTRICITÉ Générale'), 'électricité générale');
});

test('null face à null : égal ; null face à une valeur : erreur dans les deux sens', () => {
  assert.deepEqual(comparerValeur('nombre', null, null), { strict: true, normalise: true });
  assert.deepEqual(comparerValeur('identifiant', null, 'X1'), { strict: false, normalise: false });
  assert.deepEqual(comparerValeur('identifiant', 'X1', null), { strict: false, normalise: false });
});

test('extraction identique à la vérité terrain : tout est exact, ordre des clés indifférent', () => {
  // Clés des lignes dans un autre ordre, comme les renvoie PostgreSQL (JSONB).
  const lignesReordonnees = verite.lignes.map((l) => Object.fromEntries(Object.entries(l).reverse()));
  const r = comparerExtraction({ ...verite, lignes: lignesReordonnees }, verite);
  assert.equal(r.entete.length, CHAMPS_ENTETE.length);
  assert.ok(r.entete.every((c) => c.strict && c.normalise));
  assert.deepEqual([r.lignes.attendues, r.lignes.exactesStrict, r.lignes.enTrop], [3, 3, 0]);
});

test('lignes manquantes, en trop et champ faux', () => {
  const d = structuredClone(verite);
  d.lignes[1].quantite = 131;
  d.lignes.pop();
  const r = comparerExtraction(d, verite);
  assert.deepEqual([r.lignes.attendues, r.lignes.extraites, r.lignes.exactesStrict, r.lignes.enTrop], [3, 2, 1, 0]);
  const enTrop = comparerExtraction({ ...verite, lignes: [...verite.lignes, verite.lignes[0]] }, verite);
  assert.equal(enTrop.lignes.enTrop, 1);
});

test('aucune donnée (extraction en erreur) : tous les champs sont faux', () => {
  const r = comparerExtraction(null, verite);
  assert.ok(r.entete.some((c) => c.attendu === null), 'la vérité contient des champs nuls (cas piège)');
  assert.equal(r.entete.filter((c) => c.strict || c.normalise).length, 0);
  assert.equal(r.lignes.exactesStrict, 0);
});
