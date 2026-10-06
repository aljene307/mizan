// Script de réextraction du lot de développement (D-059), sur la base mizan_test.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import pg from 'pg';
import { planifierReextraction, appliquerReextraction, fichiersLotDev } from '../../scripts/reextraire-lot-dev.js';

if (existsSync('.env')) process.loadEnvFile('.env');
const client = new pg.Client({
  host: 'localhost', port: 5432, user: process.env.POSTGRES_USER, password: process.env.POSTGRES_PASSWORD, database: 'mizan_test',
});
const NOMS = ['R-ancienne.pdf', 'R-ajour.pdf', 'R-erreur.pdf', 'R-absent.pdf'];
const sha = (n) => String(n).repeat(64);
const valeur = async (sql, params = []) => Object.values((await client.query(sql, params)).rows[0] ?? {})[0];

async function facture(nom, n, statut, extraction) {
  const { rows: [{ facture_id: id }] } = await client.query(
    "SELECT facture_id FROM enregistrer_reception('dossier', $1, 'pdf', $1, $2)", [nom, sha(n)]);
  await client.query("UPDATE factures SET statut = $2, numero = 'N-' || $1::text, montant_ttc = 10 WHERE id = $1", [id, statut]);
  if (statut === 'extraite') {
    await client.query("INSERT INTO lignes_facture (facture_id, numero_ligne, designation) VALUES ($1, 1, 'A'), ($1, 2, 'B')", [id]);
  }
  await client.query(
    `INSERT INTO extractions (facture_id, fichier_sha256, resultat, code_resultat, donnees, version_chaine)
     VALUES ($1, $2, $3, $4, $5, $6)`,
    [id, sha(n), extraction.resultat, extraction.resultat === 'valide' ? 'ok' : 'reponse_illisible',
      extraction.resultat === 'valide' ? { numero: 'N' } : null, extraction.version ?? null]);
  return id;
}

before(async () => {
  await client.connect();
  await facture('R-ancienne.pdf', 1, 'extraite', { resultat: 'valide' });
  await facture('R-ajour.pdf', 2, 'extraite', { resultat: 'valide', version: 'D-053' });
  await facture('R-erreur.pdf', 3, 'erreur_extraction', { resultat: 'invalide' });
});
after(() => client.end());

test('le script ne vise que les 42 fichiers du lot de développement (ni lot de test, ni copies d\'essai)', () => {
  const noms = fichiersLotDev();
  const lots = JSON.parse(readFileSync('data/synthetic/lots.json', 'utf8'));
  const test = new Set(lots.test.map((d) => d.fichier.split('/').pop()));
  assert.equal(noms.length, 42);
  assert.ok(noms.every((n) => !test.has(n) && !/-essai\./.test(n)));
});

test('simulation : ancienne version → réextraire ; version en service → ignorer ; erreur → réextraire ; absent signalé', async () => {
  const { plan, absents } = await planifierReextraction(client, NOMS, 'D-053');
  assert.deepEqual(plan.map((p) => [p.fichier_nom, p.action]),
    [['R-ancienne.pdf', 'reextraire'], ['R-ajour.pdf', 'ignorer'], ['R-erreur.pdf', 'reextraire']]);
  assert.deepEqual(absents, ['R-absent.pdf']);
  assert.equal(await valeur("SELECT count(*)::int FROM factures WHERE statut = 'recue' AND fichier_nom LIKE 'R-%'"), 0,
    'la simulation n\'écrit rien');
});

test('refus en bloc si une facture visée a déjà des résultats de contrôle', async () => {
  const id = await facture('R-controlee.pdf', 4, 'extraite', { resultat: 'valide' });
  await client.query(
    "INSERT INTO resultats_controles (facture_id, passage, regle, version_regle, resultat, gravite) VALUES ($1, nextval('passages_controle_seq'), 'devise', '1', 'ok', 'info')", [id]);
  const { plan } = await planifierReextraction(client, [...NOMS, 'R-controlee.pdf'], 'D-053');
  assert.equal(plan.find((p) => p.fichier_nom === 'R-controlee.pdf').action, 'refuser');
  await assert.rejects(appliquerReextraction(client, plan), /R-controlee\.pdf/);
  assert.equal(await valeur("SELECT statut FROM factures WHERE fichier_nom = 'R-ancienne.pdf'"), 'extraite', 'rien n\'a été modifié');
});

test('application : statut « recue », lignes supprimées, champs vidés, journal ; anciennes extractions conservées', async () => {
  const { plan } = await planifierReextraction(client, NOMS, 'D-053');
  assert.equal(await appliquerReextraction(client, plan), 2);
  const f = (await client.query("SELECT * FROM factures WHERE fichier_nom = 'R-ancienne.pdf'")).rows[0];
  assert.deepEqual([f.statut, f.numero, f.montant_ttc, f.fournisseur_id], ['recue', null, null, null]);
  assert.equal(await valeur('SELECT count(*)::int FROM lignes_facture WHERE facture_id = $1', [f.id]), 0);
  assert.equal(await valeur('SELECT count(*)::int FROM extractions WHERE facture_id = $1', [f.id]), 1, 'extraction précédente conservée');
  const j = (await client.query("SELECT * FROM journal_audit WHERE action = 'facture.reextraction' AND entite_id = $1", [String(f.id)])).rows[0];
  assert.equal(j.donnees_avant.lignes, 2);
  assert.match(j.commentaire, /D-053/);
  assert.equal(await valeur("SELECT statut FROM factures WHERE fichier_nom = 'R-erreur.pdf'"), 'recue');
  assert.equal(await valeur("SELECT statut FROM factures WHERE fichier_nom = 'R-ajour.pdf'"), 'extraite', 'déjà à jour : non touchée');
  assert.equal(await valeur("SELECT count(*)::int FROM extraction_valide_existante($1, 'D-053')", [sha(1)]), 0,
    'l\'ancienne extraction ne sera pas réutilisée : le workflow appellera le LLM');
});
