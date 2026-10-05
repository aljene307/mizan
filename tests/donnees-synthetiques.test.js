// Tests des fichiers générés dans data/synthetic/ (ceux qui sont commités).
// Ils vérifient que les fichiers sont complets, valides, et identiques à ce
// que produit le code actuel du générateur.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { construireJeu, versVerite } from '../generateur/modele.js';
import { valider } from '../src/schemas/valider.js';
import { enMillimes } from '../src/montants.js';

const racine = new URL('../data/synthetic/', import.meta.url);
const lireJson = (chemin) => JSON.parse(readFileSync(new URL(chemin, racine), 'utf8'));
const sha256 = (chemin) => createHash('sha256').update(readFileSync(new URL(chemin, racine))).digest('hex');

const lots = lireJson('lots.json');
const verites = [...lots.dev, ...lots.test].map((d) => lireJson(`${d.fichier.split('/')[0]}/verite/${d.id}.json`));
const parId = new Map(verites.map((v) => [v.id, v]));

test('lots.json : 60 documents, chaque document dans un seul lot', () => {
  assert.equal(lots.dev.length + lots.test.length, 60);
  assert.equal(new Set(verites.map((v) => v.id)).size, 60);
  for (const lot of ['dev', 'test']) {
    for (const d of lots[lot]) assert.equal(parId.get(d.id).lot, lot, d.id);
    const fichiers = readdirSync(new URL(`${lot}/documents/`, racine));
    assert.equal(fichiers.length, lots[lot].length, `${lot} : fichiers en trop ou manquants`);
  }
});

test('chaque vérité terrain respecte le schéma et l\'empreinte de son fichier', () => {
  for (const v of verites) {
    assert.deepEqual(valider('verite', v), [], v.id);
    const chemin = `${v.lot}/documents/${v.fichier}`;
    assert.ok(existsSync(new URL(chemin, racine)), chemin);
    assert.equal(sha256(chemin), v.sha256, v.id);
  }
});

test('doublon exact = même empreinte ; doublon rescanné = empreinte différente', () => {
  for (const v of verites) {
    const code = v.anomalies_attendues.map((a) => a.code);
    if (code.includes('doublon_exact')) assert.equal(v.sha256, parId.get(v.derive_de).sha256, v.id);
    if (code.includes('doublon_rescanne')) assert.notEqual(v.sha256, parId.get(v.derive_de).sha256, v.id);
  }
});

test('les fichiers commités correspondent au code actuel du générateur', () => {
  const jeu = construireJeu({ config: lireJson('config-fiscale.json'), graine: lots.graine });
  for (const doc of jeu.documents) {
    const attendue = versVerite(doc, jeu.entreprise);
    const { sha256: _, ...commitee } = parId.get(doc.id);
    const { sha256: __, ...regeneree } = attendue;
    assert.deepEqual(commitee, regeneree, `${doc.id} : relancer « npm run generer »`);
  }
});

test('référentiel : les fournisseurs inconnus en sont absents', () => {
  const fournisseurs = lireJson('referentiel/fournisseurs.json');
  const codes = new Set(fournisseurs.map((f) => f.code));
  for (const v of verites) {
    const inconnu = v.anomalies_attendues.some((a) => a.code === 'fournisseur_inconnu');
    assert.equal(v.fournisseur_code === null, inconnu, v.id);
    if (!inconnu) assert.ok(codes.has(v.fournisseur_code), v.id);
  }
});

test('relevé CSV : en-tête, soldes et montants des appariements', () => {
  const attendus = lireJson('releve/appariements-attendus.json');
  const lignes = readFileSync(new URL(`releve/${attendus.fichier}`, racine), 'utf8').trimEnd().split('\n');
  assert.equal(lignes[0], 'date_operation;date_valeur;libelle;reference;debit;credit;solde');
  const montant = (t) => (t === '' ? 0 : enMillimes(t.replace(',', '.')));
  let solde = enMillimes(attendus.solde_initial);
  const operations = lignes.slice(1).map((ligne) => {
    const [, , libelle, , debit, credit, soldeLu] = ligne.split(';');
    solde += montant(credit) - montant(debit);
    assert.equal(montant(soldeLu), solde, libelle);
    return { debit: montant(debit) };
  });
  assert.equal(solde, enMillimes(attendus.solde_final));
  for (const a of attendus.appariements) {
    assert.equal(operations[a.numero_ligne - 1].debit, enMillimes(a.montant_operation), `ligne ${a.numero_ligne}`);
  }
  const couvertes = new Set([...attendus.appariements.map((a) => a.numero_ligne), ...attendus.lignes_sans_facture]);
  assert.equal(couvertes.size, operations.length);
});
