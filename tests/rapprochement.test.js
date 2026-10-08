// Lecture du relevé et appariement (D-065) : un test par cas.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { lireReleveCsv, lireMontant, lireDate } from '../src/rapprochement/releve.js';
import { rapprocher, numeroDansLibelle, abreviation } from '../src/rapprochement/appariement.js';
import { enMillimes } from '../src/montants.js';

const deps = { enMillimes };

// --- Lecture du CSV ----------------------------------------------------------------
test('montants et dates : virgule décimale, JJ/MM/AAAA, refus de ce qui est illisible', () => {
  assert.equal(lireMontant('3500,000', 1, 'débit'), 3500);
  assert.equal(lireMontant('29808,787', 1, 'crédit'), 29808.787);
  assert.equal(lireMontant('', 1, 'débit'), 0);
  assert.throws(() => lireMontant('3.500,00', 1, 'débit'), /illisible/);
  assert.equal(lireDate('05/01/2026', 1, 'date'), '2026-01-05');
  assert.throws(() => lireDate('31/02/2026', 1, 'date'), /impossible/);
  assert.throws(() => lireDate('2026-01-05', 1, 'date'), /illisible/);
});

test('le relevé synthétique se lit entièrement ; soldes initial et final déduits', () => {
  const r = lireReleveCsv(readFileSync('data/synthetic/releve/releve-2026-01-01_2026-09-30.csv', 'utf8'));
  const attendu = JSON.parse(readFileSync('data/synthetic/releve/appariements-attendus.json', 'utf8'));
  assert.equal(r.lignes.length, 103);
  assert.equal(r.solde_initial, attendu.solde_initial);
  assert.equal(r.solde_final, attendu.solde_final);
  assert.deepEqual([r.date_debut, r.lignes[0].date_operation, r.lignes[0].libelle], ['2026-01-05', '2026-01-05', 'PRLV LOYER LOCAUX']);
  // Contrôle refait ici comme en base : solde précédent + crédit − débit (en millimes).
  let solde = Math.round(r.solde_initial * 1000);
  for (const l of r.lignes) {
    solde += Math.round(l.credit * 1000) - Math.round(l.debit * 1000);
    assert.equal(solde, Math.round(l.solde * 1000), `ligne ${l.numero_ligne}`);
  }
});

test('en-tête ou colonnes inattendus : refus explicite', () => {
  assert.throws(() => lireReleveCsv('date;libelle\n01/01/2026;x'), /en-tête inattendu/);
  assert.throws(() => lireReleveCsv('date_operation;date_valeur;libelle;reference;debit;credit;solde\n05/01/2026;;X;;1,000'), /colonnes/);
  assert.throws(() => lireReleveCsv('date_operation;date_valeur;libelle;reference;debit;credit;solde\n05/01/2026;;X;;1,000;2,000;0'), /incohérents/);
});

// --- Appariement ------------------------------------------------------------------
let n = 0;
const facture = (numero, ttc, modif = {}) => ({
  id: (n += 1), statut: 'conforme', type_document: 'facture', numero, devise: 'TND', montant_ttc: ttc,
  date_facture: '2026-03-01', date_echeance: '2026-03-31', fournisseur_id: 1, raison_sociale: 'Yasmine Services Nettoyage',
  deja_paye: 0, ...modif,
});
const ligne = (id, libelle, debit, modif = {}) => ({ id, numero_ligne: id, date_operation: '2026-03-20', libelle, debit, credit: 0, ...modif });
const contexte = (lignes, factures, modif = {}) => ({
  lignes, factures, rejetees: [],
  categories: [{ code: 'loyer', sens: 'debit', motif: '^PRLV LOYER\\b' }, { code: 'encaissement_client', sens: 'credit', motif: '^VIR RECU\\b' }],
  parametres: { 'rapprochement.tolerance_ecart': 5, 'rapprochement.fenetre_jours': 180 }, ...modif,
});
const unique = (r) => { assert.equal(r.propositions.length, 1); return r.propositions[0]; };

test('outils : numéro entier dans le libellé, abréviation bancaire du fournisseur', () => {
  assert.ok(numeroDansLibelle('2026/131', 'VIR EMIS YASMINE SERVICES NETTO FACT 2026/131'));
  assert.ok(!numeroDansLibelle('2026/13', 'VIR EMIS X FACT 2026/131'), 'pas un numéro tronqué');
  assert.ok(numeroDansLibelle('fa-2026-0263', 'VIR X FACT FA-2026-0263 DED AV AV-2026-003'));
  assert.equal(abreviation('Électricité Générale Hammamet'), 'ELECTRICITE GENERALE H');
});

test('exact, numéro dans le libellé, facture approuvée : confirmé automatiquement', () => {
  const f = facture('2026/131', 2558.619);
  const p = unique(rapprocher(contexte([ligne(1, 'VIR EMIS YASMINE SERVICES NETTO FACT 2026/131', 2558.619)], [f]), deps));
  assert.deepEqual([p.cas, p.auto, p.ecart, p.affectations], ['exact', true, 0, [{ facture_id: f.id, montant: 2558.619, role: 'reglement' }]]);
  assert.match(p.raisons.join(' '), /numéro 2026\/131/);
});

test('chèque : montant seul → proposé, jamais automatique', () => {
  const f = facture('X-1', 500);
  const p = unique(rapprocher(contexte([ligne(1, 'CHEQUE N 1234567', 500)], [f]), deps));
  assert.deepEqual([p.cas, p.auto], ['exact', false]);
  assert.match(p.raisons.join(' '), /chèque/);
});

test('virement sans numéro, fournisseur reconnu : proposé (score plus élevé qu\'un chèque)', () => {
  const f = facture('X-2', 800, { raison_sociale: 'Oasis Gardiennage et Sécurité' });
  const autre = facture('X-3', 800, { raison_sociale: 'Mejerda Agro-Fournitures', fournisseur_id: 2 });
  const p = unique(rapprocher(contexte([ligne(1, 'VIREMENT FAVEUR OASIS GARDIENNAGE ET S', 800)], [f, autre]), deps));
  assert.equal(p.affectations[0].facture_id, f.id, 'le fournisseur reconnu départage');
  assert.equal(p.auto, false);
  assert.equal(p.score, 0.8);
});

test('plusieurs factures de même montant : proposé avec un score réduit, raison explicite', () => {
  const p = unique(rapprocher(contexte([ligne(1, 'CHEQUE N 1', 300)], [facture('A', 300), facture('B', 300, { date_echeance: '2026-03-21' })]), deps));
  assert.equal(p.score, 0.4);
  assert.match(p.raisons.join(' '), /2 factures approuvées de même montant/);
});

test('virement groupé : deux numéros, somme des restes', () => {
  const a = facture('2026/155', 3187.487);
  const b = facture('2026/137', 3518.676);
  const p = unique(rapprocher(contexte([ligne(1, 'VIR EMIS YASMINE SERVICES NETTO FACT 2026/155 2026/137', 6706.163)], [a, b]), deps));
  assert.deepEqual([p.cas, p.auto, p.ecart], ['groupe', false, 0]);
  assert.deepEqual(p.affectations.map((x) => x.facture_id).sort(), [a.id, b.id].sort());
});

test('paiement net d\'un avoir : facture réglée, avoir imputé, sortie plus faible', () => {
  const f = facture('FA-2026-0263', 355.025);
  const av = facture('AV-2026-003', 70.805, { type_document: 'avoir' });
  const p = unique(rapprocher(contexte([ligne(1, 'VIR EMIS PAPETERIE ENNOUR BUREA FACT FA-2026-0263 DED AV AV-2026-003', 284.22)], [f, av]), deps));
  assert.deepEqual([p.cas, p.ecart], ['net_avoir', 0]);
  assert.deepEqual(p.affectations, [{ facture_id: f.id, montant: 355.025, role: 'reglement' }, { facture_id: av.id, montant: 70.805, role: 'imputation_avoir' }]);
});

test('acompte puis solde dans le même relevé : deux « partiel », aucun automatique', () => {
  const f = facture('ISS260287', 8027.02);
  const r = rapprocher(contexte([
    ligne(1, 'VIR EMIS INFOSAHEL SYSTEMES ACOMPTE FACT ISS260287', 3211),
    ligne(2, 'VIR EMIS INFOSAHEL SYSTEMES SOLDE FACT ISS260287', 4816.02, { date_operation: '2026-04-20' }),
  ], [f]), deps);
  assert.deepEqual(r.propositions.map((p) => [p.cas, p.auto, p.affectations[0].montant]), [['partiel', false, 3211], ['partiel', false, 4816.02]]);
  assert.match(r.propositions[1].raisons.join(' '), /solde/);
});

test('écart dans la tolérance (2 TND) : proposé avec l\'écart ; au-delà : partiel', () => {
  const f = facture('ISS260268', 6462.081);
  const p = unique(rapprocher(contexte([ligne(1, 'VIR INFOSAHEL SYSTEMES REF ISS260268', 6460.081)], [f]), deps));
  assert.deepEqual([p.cas, p.auto, p.ecart, p.affectations[0].montant], ['ecart', false, -2, 6462.081]);
  const loin = unique(rapprocher(contexte([ligne(1, 'VIR X REF ISS260268', 6000)], [facture('ISS260268', 6462.081)]), deps));
  assert.equal(loin.cas, 'partiel');
  const serre = unique(rapprocher(contexte([ligne(1, 'VIR X REF ISS260268', 6460.081)], [facture('ISS260268', 6462.081)],
    { parametres: { 'rapprochement.tolerance_ecart': 1, 'rapprochement.fenetre_jours': 180 } }), deps));
  assert.equal(serre.cas, 'partiel', 'la tolérance vient de la table de configuration');
});

test('facture citée mais non approuvée : signalement, pas de proposition', () => {
  const f = facture('2026/153', 1000, { statut: 'anomalie' });
  const r = rapprocher(contexte([ligne(1, 'VIR EMIS YASMINE SERVICES NETTO FACT 2026/153', 1000)], [f]), deps);
  assert.equal(r.propositions.length, 0);
  assert.deepEqual(r.signalements.map((s) => [s.type, s.facture_id]), [['payee_non_approuvee', f.id]]);
  assert.match(r.signalements[0].message, /anomalie/);
});

test('doublon rejeté dont l\'original est approuvé (cas D056/D035) : rapproché de l\'approuvé, aucun signalement', () => {
  const rejetee = facture('TCL-00329', 900, { statut: 'rejetee' });
  const approuvee = facture('TCL-00329', 900);
  const r = rapprocher(contexte([ligne(1, 'VIR EMIS TRANS-CAP LOGISTIQUE FACT TCL-00329', 900)], [rejetee, approuvee]), deps);
  assert.deepEqual(r.signalements, []);
  assert.equal(unique(r).affectations[0].facture_id, approuvee.id);
});

test('montant égal à une facture non approuvée, sans numéro : signalement « payée sans être approuvée »', () => {
  const f = facture('X', 444, { statut: 'bloquee' });
  const r = rapprocher(contexte([ligne(1, 'CHEQUE N 99', 444)], [f]), deps);
  assert.deepEqual(r.signalements.map((s) => [s.type, s.detail.par]), [['payee_non_approuvee', 'montant']]);
});

test('catégories : sortie connue rangée ; encaissement rangé ; sortie inconnue signalée ; encaissement inconnu ignoré', () => {
  const r = rapprocher(contexte([
    ligne(1, 'PRLV LOYER LOCAUX', 3500), ligne(2, 'VIR RECU CLIENT X', 0, { credit: 100 }),
    ligne(3, 'VIR EMIS INCONNU SARL', 77), ligne(4, 'REMISE INCONNUE', 0, { credit: 5 }),
  ], [facture('Z', 999)]), deps);
  assert.deepEqual(r.categories, [{ ligne_releve_id: 1, categorie: 'loyer' }, { ligne_releve_id: 2, categorie: 'encaissement_client' }]);
  assert.deepEqual(r.signalements.map((s) => [s.ligne_releve_id, s.type]), [[3, 'sortie_sans_facture']]);
  assert.deepEqual(r.propositions, []);
});

test('fenêtre de dates : une facture payée longtemps après n\'est pas candidate par le montant seul', () => {
  const f = facture('V', 250, { date_facture: '2025-01-01' });
  const r = rapprocher(contexte([ligne(1, 'CHEQUE N 5', 250)], [f]), deps);
  assert.deepEqual(r.signalements.map((s) => s.type), ['sortie_sans_facture']);
});

test('proposition déjà rejetée pour cette ligne et ces factures : pas reproposée', () => {
  const f = facture('R-1', 120);
  const r = rapprocher(contexte([ligne(7, 'CHEQUE N 7', 120)], [f], { rejetees: [{ ligne_releve_id: 7, factures: [f.id] }] }), deps);
  assert.deepEqual(r.propositions, []);
});

test('numéro du libellé à un caractère du numéro lu (erreur d\'OCR, cas D024) : proposé, jamais automatique', () => {
  // La facture a été lue « 1S5260287 » ; la banque écrit « ISS260287 ».
  const f = facture('1S5260287', 8027.02, { raison_sociale: 'InfoSahel Systèmes' });
  const r = rapprocher(contexte([
    ligne(1, 'VIR EMIS INFOSAHEL SYSTEMES ACOMPTE FACT ISS260287', 3211),
    ligne(2, 'VIR EMIS INFOSAHEL SYSTEMES SOLDE FACT ISS260287', 4816.02),
  ], [f]), deps);
  assert.deepEqual(r.propositions.map((p) => [p.cas, p.auto, p.affectations[0].facture_id]), [['partiel', false, f.id], ['partiel', false, f.id]]);
  assert.match(r.propositions[0].raisons[0], /proche du numéro lu « 1S5260287 »/);
  assert.ok(r.propositions.every((p) => p.score <= 0.6), 'score plafonné');
  const exact = unique(rapprocher(contexte([ligne(1, 'VIR EMIS INFOSAHEL SYSTEMES FACT ISS260287', 8027.02)], [facture('1S5260287', 8027.02, { raison_sociale: 'InfoSahel Systèmes' })]), deps));
  assert.deepEqual([exact.cas, exact.auto], ['exact', false], 'montant exact mais numéro approchant : pas automatique');
});

test('numéro approchant mais fournisseur absent du libellé : rien n\'est déduit', () => {
  const r = rapprocher(contexte([ligne(1, 'VIR EMIS AUTRE SOCIETE FACT ISS260287', 123)], [facture('1S5260287', 999, { raison_sociale: 'InfoSahel Systèmes' })]), deps);
  assert.deepEqual(r.propositions, []);
  assert.deepEqual(r.signalements.map((s) => s.type), ['sortie_sans_facture']);
});

test('numéros proches : confusions de lecture admises, numéros réellement différents distingués', async () => {
  const { numeroProcheDansLibelle } = await import('../src/rapprochement/appariement.js');
  assert.equal(numeroProcheDansLibelle('1S5260287', 'VIR X FACT ISS260287'), 'ISS260287', 'I→1, S→5');
  assert.equal(numeroProcheDansLibelle('MAF0O134', 'VIR X FACT MAF00134'), 'MAF00134', 'O→0');
  // Défaut trouvé par la mesure : des numéros consécutifs d'un même fournisseur étaient rapprochés.
  assert.equal(numeroProcheDansLibelle('2026/137', 'VIR X FACT 2026/131'), null, 'factures consécutives : un chiffre pour un autre, jamais');
  assert.equal(numeroProcheDansLibelle('MC2026-00078', 'VIR X REF MC2026-00073'), null, 'factures consécutives');
  assert.equal(numeroProcheDansLibelle('ISS260287', 'VIR X FACT ISS260288'), null, 'un chiffre différent : une autre facture');
  assert.equal(numeroProcheDansLibelle('ISS260287', 'VIR X FACT ISS261299'), null, 'trois chiffres différents : autre facture');
  assert.equal(numeroProcheDansLibelle('2026/13', 'VIR X FACT 2026/131'), null, 'numéros trop courts : pas d\'approximation');
});
