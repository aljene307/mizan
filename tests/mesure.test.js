import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { CONFIGURATIONS, DEVISES_LISTE, DOCUMENTS_STABILITE, schemaPourConfiguration, cleAppel, estCopieEssai } from '../eval/mesure-commun.js';

const schemaStrict = JSON.parse(readFileSync('src/schemas/extraction-facture.schema.json', 'utf8'));
const lots = JSON.parse(readFileSync('data/synthetic/lots.json', 'utf8'));

test('4 configurations : 2 prompts × 2 schémas', () => {
  assert.deepEqual(CONFIGURATIONS.map((c) => c.id), ['v1-libre', 'v1-liste', 'v2-libre', 'v2-liste']);
});

test('schéma « liste » : devise en liste fermée avec AUTRE ; « libre » : inchangé', () => {
  const liste = schemaPourConfiguration(schemaStrict, CONFIGURATIONS[1]);
  assert.deepEqual(liste.properties.devise, { type: 'string', enum: [...DEVISES_LISTE] });
  assert.ok(DEVISES_LISTE.includes('AUTRE'));
  const libre = schemaPourConfiguration(schemaStrict, CONFIGURATIONS[0]);
  assert.deepEqual(libre.properties.devise, { type: 'string' });
  assert.equal(schemaStrict.properties.devise.pattern, '^[A-Z]{3}$', 'le schéma strict n\'est pas modifié');
});

test('les documents de la mesure de stabilité appartiennent au lot de développement (D-026)', () => {
  const dev = new Set(lots.dev.map((d) => d.id));
  for (const id of DOCUMENTS_STABILITE) assert.ok(dev.has(id), `${id} n'est pas dans le lot dev`);
  assert.equal(DOCUMENTS_STABILITE.length, 10);
});

test('clé de reprise : configuration, document, passage', () => {
  assert.equal(cleAppel({ configuration: 'v1-libre', document: 'D001', passage: 2 }), 'v1-libre|D001|2');
});

test('copies d\'essai exclues des rapports ; aucun fichier des deux lots n\'est pris pour une copie (D-054)', () => {
  for (const nom of ['D023-essai.pdf', 'D011-essai.pdf', 'D001-essai.jpg', 'D001-ESSAI.JPG']) assert.ok(estCopieEssai(nom), nom);
  for (const d of [...lots.dev, ...lots.test]) assert.equal(estCopieEssai(d.fichier.split('/').pop()), false, d.fichier);
  assert.equal(estCopieEssai(null), false);
});
