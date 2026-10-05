// Chargement du référentiel fictif, sur la base de test mizan_test.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import pg from 'pg';
import { chargerReferentiel } from '../../scripts/charger-referentiel.js';

if (existsSync('.env')) process.loadEnvFile('.env');
const fournisseurs = JSON.parse(readFileSync('data/synthetic/referentiel/fournisseurs.json', 'utf8'));
const client = new pg.Client({
  host: 'localhost', port: 5432, user: 'mizan_app', password: process.env.MIZAN_APP_PASSWORD, database: 'mizan_test',
});
const compter = async (sql) => (await client.query(sql)).rows[0].n;

before(() => client.connect());
after(() => client.end());

test('premier chargement : 12 fournisseurs et 12 RIB actifs, tracés au journal', async () => {
  const resultat = await chargerReferentiel(client, fournisseurs);
  assert.deepEqual(resultat, { fournisseursCrees: 12, ribsCrees: 12 });
  assert.equal(await compter("SELECT count(*)::int AS n FROM fournisseurs WHERE matricule_fiscal LIKE '99%'"), 12);
  assert.equal(await compter('SELECT count(*)::int AS n FROM fournisseur_ribs WHERE valide_au IS NULL'), 12);
  assert.equal(await compter("SELECT count(*)::int AS n FROM journal_audit WHERE acteur = 'script:charger-referentiel'"), 24);
});

test('second chargement : rien n\'est créé (idempotent)', async () => {
  const resultat = await chargerReferentiel(client, fournisseurs);
  assert.deepEqual(resultat, { fournisseursCrees: 0, ribsCrees: 0 });
  assert.equal(await compter('SELECT count(*)::int AS n FROM fournisseur_ribs'), 12);
});

test('un RIB différent de celui en base est refusé, sans rien écrire', async () => {
  const modifie = structuredClone(fournisseurs);
  modifie[0].rib = '99000000000000000097';
  await assert.rejects(chargerReferentiel(client, modifie), /RIB actif en base diffère/);
  assert.equal(await compter('SELECT count(*)::int AS n FROM fournisseur_ribs'), 12);
});

test('les fournisseurs « inconnus » des pièges ne sont pas dans le référentiel', () => {
  const noms = fournisseurs.map((f) => f.raison_sociale);
  assert.ok(!noms.includes('Djerba Express Fournitures'));
  assert.ok(!noms.includes('Kairouan Pro Équipement'));
});
