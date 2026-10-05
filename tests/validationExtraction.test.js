// Le validateur sans dépendance (copié dans n8n) doit donner le même verdict
// qu'ajv, la bibliothèque de référence, sur des extractions valides et sur
// des extractions volontairement fautives. Seul le lot de développement est
// utilisé (le lot de test est réservé à l'étape 8, D-026).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import {
  validerSchema, verifierCompatibiliteBase, validerExtraction, estDateValide,
} from '../src/validationExtraction.js';
import { valider as validerAjv } from '../src/schemas/valider.js';
import { creerAlea } from '../generateur/alea.js';

const schema = JSON.parse(readFileSync(new URL('../src/schemas/extraction-facture.schema.json', import.meta.url), 'utf8'));
const dossierDev = new URL('../data/synthetic/dev/verite/', import.meta.url);
const extractionsDev = readdirSync(dossierDev).map((f) => JSON.parse(readFileSync(new URL(f, dossierDev), 'utf8')).extraction);
const memeVerdict = (donnees, libelle) => {
  const ajvValide = validerAjv('extraction', donnees).length === 0;
  const notreValide = validerSchema(schema, donnees).length === 0;
  assert.equal(notreValide, ajvValide, `${libelle} : ajv dit ${ajvValide}, notre validateur dit ${notreValide}`);
  return notreValide;
};
const copie = (o) => structuredClone(o);

test('les 42 vérités terrain du lot de développement sont valides (comme pour ajv)', () => {
  assert.equal(extractionsDev.length, 42);
  for (const [i, e] of extractionsDev.entries()) assert.equal(memeVerdict(e, `dev ${i}`), true);
});

const MUTATIONS = {
  'champ obligatoire absent': (e) => { delete e.numero; },
  'propriété non prévue': (e) => { e.commentaire = 'x'; },
  'propriété non prévue dans fournisseur': (e) => { e.fournisseur.telephone = '71000000'; },
  'propriété non prévue dans une ligne': (e) => { e.lignes[0].remise = 0; },
  'champ de ligne absent': (e) => { delete e.lignes[0].taux_tva; },
  'type_document inconnu': (e) => { e.type_document = 'bon_de_livraison'; },
  'numéro vide': (e) => { e.numero = ''; },
  'numéro null': (e) => { e.numero = null; },
  'date impossible (30 février)': (e) => { e.date_facture = '2026-02-30'; },
  'date au format JJ/MM/AAAA': (e) => { e.date_facture = '15/03/2026'; },
  'mois 13': (e) => { e.date_echeance = '2026-13-01'; },
  'échéance null (autorisée)': (e) => { e.date_echeance = null; },
  'devise en minuscules': (e) => { e.devise = 'tnd'; },
  'devise à 4 lettres': (e) => { e.devise = 'TNDD'; },
  'montant négatif': (e) => { e.montant_ttc = -1; },
  'montant en texte': (e) => { e.montant_ht = '1 234,500'; },
  'timbre null (autorisé)': (e) => { e.droit_timbre = null; },
  'TVA null (interdit)': (e) => { e.montant_tva = null; },
  'aucune ligne': (e) => { e.lignes = []; },
  'lignes absentes': (e) => { delete e.lignes; },
  'quantité nulle': (e) => { e.lignes[0].quantite = 0; },
  'taux de TVA à 101 %': (e) => { e.lignes[0].taux_tva = 101; },
  'désignation vide': (e) => { e.lignes[0].designation = ''; },
  'client sans raison sociale': (e) => { delete e.client.raison_sociale; },
  'matricule null (autorisé)': (e) => { e.fournisseur.matricule_fiscal = null; },
  'RIB numérique au lieu de texte': (e) => { e.fournisseur.rib = 99123; },
  'fournisseur null': (e) => { e.fournisseur = null; },
  'extraction réduite à un tableau': () => [],
  'extraction null': () => null,
};

test('mutations ciblées : même verdict qu\'ajv', () => {
  const autorisees = ['échéance null (autorisée)', 'timbre null (autorisé)', 'matricule null (autorisé)'];
  for (const [nom, muter] of Object.entries(MUTATIONS)) {
    const e = copie(extractionsDev[0]);
    const resultat = muter(e);
    const donnees = resultat === undefined ? e : resultat;
    const valide = memeVerdict(donnees, nom);
    assert.equal(valide, autorisees.includes(nom), `${nom} : verdict inattendu`);
  }
});

test('500 mutations aléatoires : même verdict qu\'ajv', () => {
  const alea = creerAlea(42);
  const noms = Object.keys(MUTATIONS).filter((n) => !n.startsWith('extraction'));
  let invalides = 0;
  for (let i = 0; i < 500; i += 1) {
    const e = copie(alea.choix(extractionsDev));
    for (let k = 0; k < alea.entier(1, 3); k += 1) {
      try { MUTATIONS[alea.choix(noms)](e); } catch { /* mutation sans objet après une autre */ }
    }
    if (!memeVerdict(e, `mutation aléatoire ${i}`)) invalides += 1;
  }
  assert.ok(invalides > 300, `la plupart des mutations produisent une extraction invalide (${invalides}/500)`);
});

test('les messages d\'erreur indiquent le chemin du champ fautif', () => {
  const e = copie(extractionsDev[0]);
  e.lignes[0].taux_tva = 101;
  e.devise = 'tnd';
  const erreurs = validerSchema(schema, e);
  assert.ok(erreurs.some((m) => m.startsWith('/lignes/0/taux_tva')), erreurs.join(' | '));
  assert.ok(erreurs.some((m) => m.startsWith('/devise')), erreurs.join(' | '));
});

test('un mot-clé de schéma inconnu lève une erreur au lieu d\'être ignoré', () => {
  assert.throws(() => validerSchema({ type: 'string', maxLength: 3 }, 'abc'), /non pris en charge : maxLength/);
  assert.throws(() => validerSchema({ type: 'string', format: 'email' }, 'a@b.c'), /format non pris en charge/);
});

test('dates : années bissextiles', () => {
  assert.ok(estDateValide('2028-02-29'));
  assert.ok(!estDateValide('2026-02-29'));
  assert.ok(estDateValide('2000-02-29'));
  assert.ok(!estDateValide('2100-02-29'));
});

test('compatibilité avec la base : décimales et capacité des colonnes', () => {
  const e = copie(extractionsDev[0]);
  assert.deepEqual(verifierCompatibiliteBase(e), []);
  e.montant_ttc = 12.3456;
  e.lignes[0].taux_tva = 19.12345;
  e.lignes[0].quantite = 1e13;
  const erreurs = verifierCompatibiliteBase(e);
  assert.ok(erreurs.includes('/montant_ttc a plus de 3 décimales'), erreurs.join(' | '));
  assert.ok(erreurs.includes('/lignes/0/taux_tva a plus de 4 décimales'), erreurs.join(' | '));
  assert.ok(erreurs.includes('/lignes/0/quantite dépasse la capacité de la colonne'), erreurs.join(' | '));
});

test('validerExtraction : schéma d\'abord, compatibilité ensuite', () => {
  assert.deepEqual(validerExtraction(schema, extractionsDev[0]), { valide: true, erreurs: [] });
  const e = copie(extractionsDev[0]);
  e.montant_ht = 1.2345;
  assert.equal(validerExtraction(schema, e).valide, false);
  assert.equal(validerExtraction(schema, null).valide, false);
});
