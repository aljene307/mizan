// Fichier des ordres à signer (C-b1) et relevé de démonstration (D-068) :
// formats, montants en millimes, et relecture du relevé par le vrai lecteur
// et le vrai appariement.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { csvOrdres, recapitulatif } from '../scripts/exporter-ordres.js';
import { construireReleveDemo } from '../scripts/generer-releve-demo.js';
import { lireReleveCsv } from '../src/rapprochement/releve.js';
import { rapprocher } from '../src/rapprochement/appariement.js';
import { enMillimes } from '../src/montants.js';

const RIB = '99001000000000000165';
const ordre = (modif = {}) => ({
  lot_id: 3, ordre_id: 11, decide_le: '2026-10-09 08:15:00+01', beneficiaire: 'Yasmine Services; Nettoyage', rib_paiement: RIB,
  montant: '2558.619', devise: 'TND', reference: 'FACT 2026/131', numero: '2026/131', ...modif,
});

test('CSV des ordres : en-tête fixe, « ; », virgule décimale, RIB du référentiel, aucun « ; » parasite', () => {
  const lignes = csvOrdres([ordre(), ordre({ ordre_id: 12, montant: '0.1', reference: 'FACT X', numero: 'X' })]).trimEnd().split('\r\n');
  assert.equal(lignes[0], 'lot;ordre;date_approbation;beneficiaire;rib_beneficiaire;montant;devise;motif;facture');
  assert.equal(lignes[1], `3;11;2026-10-09;Yasmine Services  Nettoyage;${RIB};2558,619;TND;FACT 2026/131;2026/131`);
  assert.equal(lignes[2].split(';')[5], '0,100');
  assert.ok(lignes.every((l) => l.split(';').length === 9));
});

test('récapitulatif : total exact en millimes, rappel du RIB du référentiel', () => {
  const r = recapitulatif([ordre({ montant: '0.1' }), ordre({ montant: '0.2' })]);
  assert.match(r, /2 ordre\(s\), total 0,300 TND/);
  assert.match(r, /jamais celui lu sur une facture/);
});

test('relevé de démo : lu par le vrai lecteur, soldes cohérents, rien avant le lendemain du dernier relevé', () => {
  const r = construireReleveDemo({
    soldeInitial: '246654.030', dateReleve: '2026-09-30',
    ordres: [{ numero: 'ISS260287', beneficiaire: 'Société Industrielle du Sahel', reste_a_executer: '1000.000', decide_le: '2026-10-09' }],
    sansOrdre: { numero: 'FA-2026-0300', fournisseur: 'Papeterie Ennour Bureautique', reste_a_payer: '131.055' },
  });
  const lu = lireReleveCsv(r.csv);
  assert.equal(lu.lignes.length, 4);
  assert.equal(enMillimes(lu.solde_initial), enMillimes('246654.030'));
  assert.equal(enMillimes(lu.solde_final), r.soldeFinal);
  assert.equal(r.soldeFinal, enMillimes('246654.030') - enMillimes('1000') - enMillimes('131.055') - 2 * enMillimes('1.2'));
  assert.ok(lu.lignes.every((l) => l.date_operation >= '2026-10-01'));
  assert.deepEqual(lu.lignes.map((l) => l.libelle), [
    'VIR EMIS SOCIETE INDUSTRIELLE D FACT ISS260287', 'COMMISSION SUR VIREMENT',
    'VIR EMIS PAPETERIE ENNOUR BUREA FACT FA-2026-0300', 'COMMISSION SUR VIREMENT']);
});

test('relevé de démo : la sortie sans ordre est appariée comme un paiement ordinaire (rien ne la trahit)', () => {
  const r = construireReleveDemo({
    soldeInitial: '1000', dateReleve: '2026-09-30', ordres: [],
    sansOrdre: { numero: 'FA-2026-0300', fournisseur: 'Papeterie Ennour Bureautique', reste_a_payer: '131.055' },
  });
  const lu = lireReleveCsv(r.csv);
  const ctx = {
    lignes: lu.lignes.map((l, i) => ({ ...l, id: i + 1 })),
    factures: [{ id: 7, statut: 'validee', type_document: 'facture', numero: 'FA-2026-0300', devise: 'TND', montant_ttc: 131.055,
      date_facture: '2026-09-20', raison_sociale: 'Papeterie Ennour Bureautique', deja_paye: 0 }],
    rejetees: [], categories: [{ code: 'commission_virement', sens: 'debit', motif: '^COMMISSION SUR VIREMENT$' }],
    parametres: { 'rapprochement.tolerance_ecart': 5, 'rapprochement.fenetre_jours': 180 },
  };
  const a = rapprocher(ctx, { enMillimes });
  assert.deepEqual(a.propositions.map((p) => [p.ligne_releve_id, p.auto]), [[1, true]], 'confirmée automatiquement : c\'est la base qui signale l\'absence d\'ordre');
  assert.deepEqual(a.categories.map((c) => c.categorie), ['commission_virement']);
});
