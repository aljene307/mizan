// Scripts de mise en service du canal (D-062) sur la base mizan_test :
// code d'inscription (B1) et décision du second responsable fictif (D1).
// (Fichier exécuté après referentiel.test.js : le compte fictif existe.)
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import pg from 'pg';
import { creerCodeInscription, nouveauCode } from '../../scripts/creer-code-inscription.js';
import {
  demandesEnAttente, deciderCommeSecondResponsable, annulationsEnAttente, deciderAnnulationCommeSecondResponsable,
} from '../../scripts/simuler-second-responsable.js';
import { chargerUtilisateursDemo } from '../../scripts/charger-utilisateurs-demo.js';

if (existsSync('.env')) process.loadEnvFile('.env');
const client = new pg.Client({
  host: 'localhost', port: 5432, user: process.env.POSTGRES_USER, password: process.env.POSTGRES_PASSWORD, database: 'mizan_test',
});
const evenement = async (p) => (await client.query('SELECT recevoir_evenement($1::jsonb) AS r', [p])).rows[0].r;

before(async () => { await client.connect(); await chargerUtilisateursDemo(client); });
after(() => client.end());

test('code : 16 caractères sans ambiguïté, différent à chaque fois', () => {
  const a = nouveauCode();
  assert.match(a, /^[A-HJ-NP-Z2-9]{4}(-[A-HJ-NP-Z2-9]{4}){3}$/);
  assert.notEqual(a, nouveauCode());
});

test('inscription : utilisateur créé une fois, code à usage unique accepté par la base, tracé', async () => {
  const r = await creerCodeInscription(client, { nom: 'Test Inscription', role: 'responsable', canal: 'telegram' });
  assert.equal(r.cree, true);
  // Défaut du 2026-10-08 : la date d'expiration relue dans la même instruction valait NULL.
  assert.ok(r.expireLe instanceof Date, 'date d\'expiration renvoyée');
  const minutes = (r.expireLe.getTime() - Date.now()) / 60000;
  assert.ok(minutes > 29 && minutes <= 30, `valable 30 minutes (obtenu : ${minutes.toFixed(1)})`);
  const r2 = await creerCodeInscription(client, { nom: 'Test Inscription', role: 'responsable', canal: 'telegram' });
  assert.equal(r2.cree, false);
  await assert.rejects(creerCodeInscription(client, { nom: 'Test Inscription', role: 'validateur', canal: 'telegram' }), /existe déjà/);
  const { rows } = await client.query("SELECT count(*)::int AS n FROM codes_inscription WHERE code_empreinte = encode(sha256(convert_to($1, 'UTF8')), 'hex')", [r.code]);
  assert.equal(rows[0].n, 1, 'seule l\'empreinte est gardée');
  assert.equal((await evenement({ canal: 'telegram', reference: 'i-1', adresse: '700', type: 'inscription', code: r.code })).code, 'inscription_reussie');
  assert.equal((await evenement({ canal: 'telegram', reference: 'i-2', adresse: '701', type: 'inscription', code: r.code })).code, 'inscription_refusee');
});

test('second responsable fictif : décide une demande, avec les garde-fous habituels, canal « simulation »', async () => {
  const { rows: [demandeur] } = await client.query("SELECT id FROM utilisateurs WHERE nom = 'Test Inscription'");
  const { rows: [f] } = await client.query(
    "INSERT INTO fournisseurs (raison_sociale, matricule_fiscal) VALUES ('Fournisseur Simulation', '9912366A') RETURNING id");
  await client.query("INSERT INTO fournisseur_ribs (fournisseur_id, rib, valide_du) VALUES ($1, '99001000000000000165', '2026-01-01')", [f.id]);
  const { rows: [d] } = await client.query(
    `INSERT INTO demandes_referentiel (type_demande, fournisseur_id, donnees, demande_par, justification)
     VALUES ('changement_rib', $1, '{"rib": "99003000000000000269"}', $2, 'Nouveau RIB communiqué') RETURNING id`, [f.id, demandeur.id]);
  assert.ok((await demandesEnAttente(client)).some((x) => x.id === d.id));
  await assert.rejects(deciderCommeSecondResponsable(client, { demandeId: d.id, decision: 'approuvee', justification: 'Rappel fait au contact connu' }),
    /methode|check/i, 'méthode de vérification obligatoire');
  await deciderCommeSecondResponsable(client, { demandeId: d.id, decision: 'approuvee', methode: 'rib_rappel_contact_connu',
    justification: 'Rappel fait au contact connu du fournisseur' });
  const { rows: [x] } = await client.query('SELECT canal, decision FROM decisions_referentiel WHERE demande_id = $1', [d.id]);
  assert.deepEqual(x, { canal: 'simulation', decision: 'approuvee' });
  assert.ok(!(await demandesEnAttente(client)).some((y) => y.id === d.id));
});

test('annulation d\'un rapprochement (D-077) : le compte fictif approuve la demande d\'un autre responsable', async () => {
  // Rapprochement confirmé laissé par restitution-scripts.test.js (facture INT-O-1).
  const { rows: [p] } = await client.query(`SELECT x.id FROM propositions_rapprochement x JOIN rapprochements r ON r.proposition_id = x.id
    JOIN factures f ON f.id = r.facture_id WHERE f.numero = 'INT-O-1' AND x.statut = 'confirme'`);
  assert.ok(p, 'rapprochement confirmé de INT-O-1');
  const { rows: [demandeur] } = await client.query("SELECT id FROM utilisateurs WHERE nom = 'Intégration – Responsable ordres'");
  const { rows: [d] } = await client.query(`INSERT INTO demandes_annulation (proposition_id, demande_par, justification, canal)
    VALUES ($1, $2, 'Rapprochement erroné, à reprendre', 'test') RETURNING id`, [p.id, demandeur.id]);
  const attente = (await annulationsEnAttente(client)).find((a) => a.id === d.id);
  assert.match(attente.factures, /INT-O-1 \(reglement\)/);
  await deciderAnnulationCommeSecondResponsable(client, { demandeId: d.id, decision: 'approuvee', justification: 'Vérifié pour la démonstration' });
  const { rows: [x] } = await client.query(`SELECT a.canal, a.decision, p.statut FROM decisions_annulation a
    JOIN demandes_annulation d ON d.id = a.demande_id JOIN propositions_rapprochement p ON p.id = d.proposition_id WHERE a.demande_id = $1`, [d.id]);
  assert.deepEqual(x, { canal: 'simulation', decision: 'approuvee', statut: 'annule' });
  assert.ok(!(await annulationsEnAttente(client)).some((a) => a.id === d.id));
});
