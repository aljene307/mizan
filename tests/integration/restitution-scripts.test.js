// Scripts de restitution exécutés RÉELLEMENT (processus séparé, rôle
// mizan_lecture, vraie connexion) sur la base mizan_test : export des ordres
// et relevé de démonstration (D-068, D-072). Défaut du 2026-10-09 : une vue
// appelait une fonction introuvable pour mizan_lecture ; les tests SQL, en
// SET ROLE, ne l'avaient pas vu. Puis la chaîne complète : le relevé produit
// est importé et apparié ; seule la sortie sans ordre est signalée.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import pg from 'pg';
import { lireReleveCsv } from '../../src/rapprochement/releve.js';
import { rapprocher } from '../../src/rapprochement/appariement.js';
import { enMillimes } from '../../src/montants.js';

if (existsSync('.env')) process.loadEnvFile('.env');
const client = new pg.Client({
  host: 'localhost', port: 5432, user: process.env.POSTGRES_USER, password: process.env.POSTGRES_PASSWORD, database: 'mizan_test',
});
const RIB_REFERENTIEL = '99001000000000000165';
const RIB_FACTURE = '99003000000000000269';
const dossier = mkdtempSync(join(tmpdir(), 'mizan-restitution-'));
const script = (nom, ...args) => spawnSync(process.execPath, [`scripts/${nom}.js`, '--base', 'mizan_test', '--sortie', dossier, ...args],
  { encoding: 'utf8' });
let lotId;

before(async () => {
  await client.connect();
  const { rows: [u] } = await client.query(
    `INSERT INTO utilisateurs (nom, role, fictif) VALUES ('Intégration – Responsable ordres', 'responsable', TRUE) RETURNING id`);
  const { rows: [f] } = await client.query(
    `INSERT INTO fournisseurs (raison_sociale, matricule_fiscal) VALUES ('Fournisseur Ordres Intégration', '9912388C') RETURNING id`);
  await client.query(`INSERT INTO fournisseur_ribs (fournisseur_id, rib, valide_du) VALUES ($1, $2, '2026-01-01')`, [f.id, RIB_REFERENTIEL]);
  const facture = (numero, ttc, echeance) => client.query(
    `INSERT INTO factures (fichier_nom, statut, numero, fournisseur_id, canal_reception, format_source, fichier_sha256,
                           montant_ttc, devise, date_facture, date_echeance, rib_facture)
     VALUES ($1, 'validee', $1, $2, 'dossier', 'pdf', encode(sha256(convert_to($1, 'UTF8')), 'hex'), $3, 'TND', '2026-09-01', $4, $5)`,
    [numero, f.id, ttc, echeance, RIB_FACTURE]);
  await facture('INT-O-1', 500, '2026-09-30');
  // Échéance très lointaine : c'est la facture « hors ordre » que choisit le script.
  await facture('INT-O-2', 120, '2036-09-30');
  await client.query(`SELECT enregistrer_releve(jsonb_build_object(
    'banque', 'Banque Test', 'rib_compte', '99330228027133819365', 'date_debut', '2026-09-30', 'date_fin', '2026-09-30',
    'solde_initial', 10000, 'solde_final', 10000, 'fichier_nom', 'releve-integration.csv', 'fichier_sha256', repeat('9', 64),
    'lignes', '[]'::jsonb))`);
  // Un lot éventuellement en attente (autres fichiers de test) est d'abord refusé.
  await client.query(`INSERT INTO decisions_lot_paiement (lot_id, decision, utilisateur_id, justification)
    SELECT id, 'refuser', $1, 'Isolement du test d''intégration' FROM lots_paiement WHERE statut = 'propose'`, [u.id]);
  const { rows: [b] } = await client.query(`SELECT proposer_lot_paiement('{}') AS bilan`);
  lotId = Number(b.bilan.lot_id);
  await client.query(`INSERT INTO decisions_lot_paiement (lot_id, decision, utilisateur_id, justification)
    VALUES ($1, 'approuver', $2, 'Lot vérifié pour le test d''intégration')`, [lotId, u.id]);
});
after(async () => { await client.end(); rmSync(dossier, { recursive: true, force: true }); });

test('exporter-ordres : un numéro inconnu affiche les lots disponibles', () => {
  const r = script('exporter-ordres', '--lot', '999999');
  assert.equal(r.status, 1);
  assert.match(r.stderr, /lot 999999 inconnu/);
  assert.match(r.stderr, /Lots disponibles/);
  assert.match(r.stderr, new RegExp(`lot ${lotId} — approuve`));
  const liste = script('exporter-ordres');
  assert.equal(liste.status, 0, liste.stderr);
  assert.match(liste.stdout, new RegExp(`lot ${lotId} — approuve`));
});

test('exporter-ordres : fichier du lot approuvé, RIB du référentiel (jamais celui de la facture)', () => {
  const r = script('exporter-ordres', '--lot', String(lotId));
  assert.equal(r.status, 0, r.stderr);
  const csv = readFileSync(join(dossier, `lot-${lotId}.csv`), 'utf8');
  const ligne = csv.split('\r\n').find((l) => l.endsWith(';INT-O-1'));
  assert.ok(ligne, 'ordre de INT-O-1 présent');
  assert.equal(ligne.split(';')[4], RIB_REFERENTIEL);
  assert.equal(ligne.split(';')[5], '500,000');
  assert.ok(!csv.includes(RIB_FACTURE));
  assert.ok(!csv.includes(';INT-O-2'), 'échéance lointaine : pas d\'ordre');
});

test('generer-releve-demo (vraie connexion mizan_lecture) puis import : seule la sortie sans ordre est signalée', async () => {
  const r = script('generer-releve-demo');
  assert.equal(r.status, 0, r.stderr);
  const [fichier] = readdirSync(dossier).filter((f) => f.startsWith('releve-demo-'));
  const texte = readFileSync(join(dossier, fichier), 'utf8');
  const lu = lireReleveCsv(texte);
  assert.ok(lu.lignes.some((l) => l.libelle.endsWith('FACT INT-O-1') && l.debit === 500), 'paiement de l\'ordre');
  assert.ok(lu.lignes.some((l) => l.libelle.endsWith('FACT INT-O-2') && l.debit === 120), 'sortie sans ordre');
  assert.ok(lu.lignes.every((l) => l.date_operation >= '2026-10-01'), 'après la mise en service');

  // Import et appariement, comme le workflow (code de src/, garanties en base).
  const { rows: [rel] } = await client.query(`SELECT * FROM enregistrer_releve($1::jsonb)`, [{
    banque: 'Banque Test', rib_compte: '99330228027133819365', devise: 'TND', date_debut: lu.date_debut, date_fin: lu.date_fin,
    solde_initial: lu.solde_initial, solde_final: lu.solde_final, fichier_nom: fichier, lignes: lu.lignes,
    fichier_sha256: (await client.query(`SELECT encode(sha256(convert_to($1, 'UTF8')), 'hex') AS h`, [texte])).rows[0].h,
  }]);
  assert.equal(rel.nouveau, true);
  const { rows: [c] } = await client.query('SELECT contexte_rapprochement($1) AS ctx', [rel.releve_id]);
  const a = rapprocher(c.ctx, { enMillimes });
  await client.query('SELECT enregistrer_rapprochements($1::jsonb)', [{ releve_id: rel.releve_id, ...a }]);
  const { rows } = await client.query(`SELECT f.numero FROM signalements_paiement s JOIN factures f ON f.id = s.facture_id
    JOIN lignes_releve l ON l.id = s.ligne_releve_id WHERE l.releve_id = $1 AND s.type = 'sortie_sans_ordre' ORDER BY f.numero`, [rel.releve_id]);
  assert.deepEqual(rows.map((x) => x.numero), ['INT-O-2']);
});
