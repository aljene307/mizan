// Reconstruction (D-078) exécutée RÉELLEMENT sur une base dédiée : état
// « démonstration » (chiffres de la mesure publiée retrouvés), lot de test
// jamais en base, inscriptions conservées, sauvegarde relue, état
// « évaluation » vierge, refus sans confirmation.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import pg from 'pg';
import { reconstruire } from '../../scripts/reconstruire-base.js';
import { listerSauvegarde } from '../../scripts/sauvegarder-base.js';

if (existsSync('.env')) process.loadEnvFile('.env');
const BASE = 'mizan_reconstruction_test';
const sauvegardes = [];
const sansSaisie = async () => { throw new Error('aucune saisie attendue dans les tests'); };
async function requete(sql, valeurs = []) {
  const c = new pg.Client({ host: 'localhost', port: 5432, user: process.env.POSTGRES_USER, password: process.env.POSTGRES_PASSWORD, database: BASE });
  await c.connect();
  try { return (await c.query(sql, valeurs)).rows; } finally { await c.end(); }
}
after(() => {
  spawnSync('docker', ['compose', 'exec', '-T', 'postgres', 'sh', '-c', `dropdb -U "$POSTGRES_USER" --if-exists --force ${BASE}`]);
  for (const s of sauvegardes) rmSync(s, { force: true });
});

test('sans la bonne confirmation, rien n\'est fait', async () => {
  await assert.rejects(reconstruire({ base: BASE, etat: 'demonstration', confirmer: 'autre_base', saisir: sansSaisie }), /confirmation absente ou différente/);
  const r = spawnSync('docker', ['compose', 'exec', '-T', 'postgres', 'sh', '-c',
    `psql -X -tA -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT count(*) FROM pg_database WHERE datname = '${BASE}'"`], { encoding: 'utf8' });
  assert.equal(r.stdout.trim(), '0', 'base non créée');
  await assert.rejects(reconstruire({ base: 'postgres', etat: 'evaluation', confirmer: 'postgres', saisir: sansSaisie }), /base refusée/);
});

test('base de travail : refus si des workflows Mizan sont publiés, sinon confirmation exigée (jamais d\'effacement ici)', async () => {
  await assert.rejects(reconstruire({ base: process.env.MIZAN_DB ?? 'mizan', etat: 'evaluation', confirmer: 'non', saisir: sansSaisie }),
    /refus : des workflows Mizan sont publiés|confirmation absente ou différente/);
});

test('première installation : base créée sans schéma (db/init), reconstruction possible (clone propre, 2026-10-10)', async () => {
  spawnSync('docker', ['compose', 'exec', '-T', 'postgres', 'sh', '-c', `dropdb -U "$POSTGRES_USER" --if-exists --force ${BASE} && createdb -U "$POSTGRES_USER" ${BASE}`]);
  const bilan = await reconstruire({ base: BASE, etat: 'evaluation', confirmer: BASE, saisir: sansSaisie });
  if (bilan.sauvegarde) sauvegardes.push(bilan.sauvegarde);
  assert.equal(bilan.resume.factures, 0);
  assert.equal(bilan.resume.utilisateurs_conserves, 0);
});

test('état « démonstration » : 42 factures rejouées, chiffres de la mesure du rapprochement, lot de test jamais en base', async () => {
  const bilan = await reconstruire({ base: BASE, etat: 'demonstration', confirmer: BASE, saisir: sansSaisie });
  const scenario = JSON.parse(readFileSync('demo/scenario.json', 'utf8'));
  assert.equal(bilan.extractions, 42);
  assert.equal(bilan.controles, 42);
  assert.deepEqual(
    { operations: bilan.releve.operations, categorisees: bilan.releve.categorisees, confirmees_auto: bilan.releve.confirmees_auto,
      a_confirmer: bilan.releve.a_confirmer, signalements: bilan.releve.signalements },
    scenario.attendu_apres_releve,
  );
  const lots = JSON.parse(readFileSync('data/synthetic/lots.json', 'utf8'));
  const nomsTest = lots.test.map((d) => d.fichier.split('/').pop());
  const [{ n }] = await requete('SELECT count(*)::int AS n FROM factures WHERE fichier_nom = ANY ($1)', [nomsTest]);
  assert.equal(n, 0, 'aucune facture du lot de test (comparaison des noms, sans ouvrir les fichiers)');
  const [{ llm }] = await requete("SELECT count(*)::int AS llm FROM extractions WHERE execution_n8n_id IS DISTINCT FROM 'reconstruction'");
  assert.equal(llm, 0, 'toutes les extractions viennent du rejeu');
  const statuts = Object.fromEntries((await requete("SELECT fichier_nom, statut FROM factures WHERE fichier_nom IN ('D028.pdf', 'D005.jpg', 'D030.pdf', 'D056.pdf')")).map((r) => [r.fichier_nom, r.statut]));
  assert.deepEqual(statuts, { 'D005.jpg': 'validee', 'D028.pdf': 'validee', 'D030.pdf': 'bloquee', 'D056.pdf': 'bloquee' }, 'scénario : 2 validations, RIB modifié et doublon laissés en attente');
});

test('nouvelle reconstruction (« évaluation ») : sauvegarde relue, inscription et curseur conservés, aucune facture', async () => {
  const [{ id }] = await requete("INSERT INTO utilisateurs (nom, role) VALUES ('Personne Réelle', 'responsable') RETURNING id");
  await requete("INSERT INTO adresses_canal (utilisateur_id, canal, adresse) VALUES ($1, 'telegram', '424242')", [id]);
  await requete("UPDATE etats_canal SET curseur = 777 WHERE canal = 'telegram'");
  const bilan = await reconstruire({ base: BASE, etat: 'evaluation', confirmer: BASE, saisir: sansSaisie });
  sauvegardes.push(bilan.sauvegarde);
  assert.ok(bilan.sauvegarde && listerSauvegarde(bilan.sauvegarde).tables > 10, 'sauvegarde faite et relue avant d\'effacer');
  assert.equal(bilan.resume.factures, 0);
  const [u] = await requete(`SELECT u.role, u.fictif, a.adresse FROM utilisateurs u JOIN adresses_canal a ON a.utilisateur_id = u.id AND a.active
    WHERE u.nom = 'Personne Réelle'`);
  assert.deepEqual(u, { role: 'responsable', fictif: false, adresse: '424242' });
  const [{ curseur }] = await requete("SELECT curseur::int FROM etats_canal WHERE canal = 'telegram'");
  assert.equal(curseur, 777);
  const [{ fournisseurs }] = await requete('SELECT count(*)::int AS fournisseurs FROM fournisseurs');
  assert.ok(fournisseurs > 0, 'référentiel chargé');
});
