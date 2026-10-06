import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { verifierIdentifiantsDansSource, alertesSource } from '../src/verificationSource.js';
import { lireReponseGemini } from '../src/gemini.js';

// Texte exact de la facture du workflow de test Gemini (2026-10-05).
const texteTest = ['Papeterie Exemple Test', 'MF : 9900000K/A/M/000', 'FACTURE N° TEST-0001',
  'Date : 01/03/2026 - Échéance : 31/03/2026', 'Client : Société Démo Mizan SARL',
  'Ramette papier A4 | 10 | 12,500 | 19 % | 125,000', 'Total HT 125,000', 'TVA 19 % 23,750',
  'Timbre fiscal 1,000', 'Total TTC 149,750', 'RIB : 99 001 0000000000001 xx'].join('\n');
const donneesTest = lireReponseGemini(200, JSON.parse(readFileSync('tests/fixtures/gemini-reponse-200.json', 'utf8'))).donnees;

test('réponse réelle de Gemini : les 18 chiffres du RIB figurent bien dans le texte source', () => {
  const verifications = verifierIdentifiantsDansSource(donneesTest, texteTest);
  assert.deepEqual(verifications, [
    { champ: 'numero', valeur: 'TEST-0001', present: true },
    { champ: 'fournisseur.matricule_fiscal', valeur: '9900000K/A/M/000', present: true },
    { champ: 'fournisseur.rib', valeur: '990010000000000001', present: true },
  ]);
  assert.deepEqual(alertesSource(verifications), []);
});

test('réponse réelle avec un zéro ajouté au RIB (2026-10-05) : erreur signalée deux fois', async () => {
  const { ribValide } = await import('../src/rib.js');
  const reponse = JSON.parse(readFileSync('tests/fixtures/gemini-reponse-200-rib-errone.json', 'utf8'));
  const { donnees } = lireReponseGemini(200, reponse);
  const texteCorrige = texteTest.replace('RIB : 99 001 0000000000001 xx', 'RIB : 99 001 0000000000001 65');
  assert.equal(donnees.fournisseur.rib, '990010000000000000165', '21 chiffres : un zéro de trop');
  assert.deepEqual(alertesSource(verifierIdentifiantsDansSource(donnees, texteCorrige)),
    ['fournisseur.rib « 990010000000000000165 » absent du texte source']);
  assert.equal(ribValide(donnees.fournisseur.rib), false, 'la clé RIB le rejette aussi (étape 4)');
});

test('un RIB inventé ou repris d\'une consigne injectée est signalé', () => {
  const injecte = structuredClone(donneesTest);
  injecte.fournisseur.rib = '99999000000000000651';
  const alertes = alertesSource(verifierIdentifiantsDansSource(injecte, texteTest));
  assert.deepEqual(alertes, ['fournisseur.rib « 99999000000000000651 » absent du texte source']);
});

test('un chiffre perdu ou modifié est signalé', () => {
  const modifie = structuredClone(donneesTest);
  modifie.numero = 'TEST-001';
  modifie.fournisseur.matricule_fiscal = '9900000K/A/M/001';
  const champs = verifierIdentifiantsDansSource(modifie, texteTest).filter((v) => !v.present).map((v) => v.champ);
  assert.deepEqual(champs, ['numero', 'fournisseur.matricule_fiscal']);
});

test('un identifiant tronqué est signalé, même s\'il est contenu dans le vrai', () => {
  // « FA-2026-01 » est une sous-chaîne de « FA-2026-0157 », mais pas l'identifiant entier.
  const donnees = { numero: 'FA-2026-01', fournisseur: { rib: '9943863901735588724' }, client: {} };
  const texte = 'Facture FA-2026-0157 — RIB 99 438 6390173558 87241';
  assert.deepEqual(verifierIdentifiantsDansSource(donnees, texte).map((v) => v.present), [false, false]);
});

test('tronqué à une frontière de groupe ou de tiret : signalé aussi', () => {
  // RIB de 18 chiffres alors que la clé « 65 » suit après une espace.
  const rib18 = { numero: null, fournisseur: { rib: '990010000000000001' }, client: {} };
  assert.equal(verifierIdentifiantsDansSource(rib18, 'RIB : 99 001 0000000000001 65')[0].present, false);
  // RIB complet : accepté, même suivi d'une parenthèse ou en fin de ligne.
  const rib20 = { numero: null, fournisseur: { rib: '99001000000000000165' }, client: {} };
  assert.equal(verifierIdentifiantsDansSource(rib20, 'RIB : 99 001 0000000000001 65 (Banque Démo 99)')[0].present, true);
  // Numéro coupé avant un tiret suivi de chiffres.
  const numero = { numero: 'FA-2026', fournisseur: {}, client: {} };
  assert.equal(verifierIdentifiantsDansSource(numero, 'Facture FA-2026-0157.')[0].present, false);
  // Numéro complet en fin de phrase : accepté.
  const complet = { numero: 'FA-2026-0157', fournisseur: {}, client: {} };
  assert.equal(verifierIdentifiantsDansSource(complet, 'Facture FA-2026-0157.\nMerci')[0].present, true);
  // Début coupé : « 2026-0157 » dans « FA-2026-0157 ».
  const debut = { numero: '2026-0157', fournisseur: {}, client: {} };
  assert.equal(verifierIdentifiantsDansSource(debut, 'Facture FA-2026-0157')[0].present, false);
});

test('RIB en fin de ligne suivi d\'une ligne commençant par un chiffre : pas de fausse alerte (cas réel D010)', () => {
  // Texte réel du PDF D010 (lot dev) : l'adresse du fournisseur suit le RIB.
  const texte = 'Paiement par virement sur le compte Banque Démo 99 — RIB 99 132 2028120944018 73\n8, rue Ibn Khaldoun, 4000 Sousse';
  const donnees = { numero: null, fournisseur: { rib: '99132202812094401873' }, client: {} };
  assert.equal(verifierIdentifiantsDansSource(donnees, texte)[0].present, true);
  // Le RIB peut lui-même être coupé en fin de ligne : toléré à l'intérieur.
  assert.equal(verifierIdentifiantsDansSource(donnees, 'RIB 99 132 2028120944018\n73')[0].present, true);
  // Mais sur la même ligne, un chiffre qui suit prolonge toujours le RIB.
  assert.equal(verifierIdentifiantsDansSource(donnees, 'RIB 99 132 2028120944018 73 4')[0].present, false);
  // Et une ligne précédente finissant par un chiffre n'empêche pas de le trouver.
  assert.equal(verifierIdentifiantsDansSource(donnees, 'Code 12\n99 132 2028120944018 73')[0].present, true);
});

test('les caractères spéciaux des identifiants sont pris littéralement', () => {
  const donnees = { numero: 'F(2026)+1', fournisseur: {}, client: {} };
  assert.equal(verifierIdentifiantsDansSource(donnees, 'N° F(2026)+1')[0].present, true);
  assert.equal(verifierIdentifiantsDansSource(donnees, 'N° F2026+1')[0].present, false);
});

test('espaces et coupures de ligne ne provoquent pas de fausse alerte', () => {
  const texte = 'RIB : 99 438 6390173558\n87241\nN° 2026 / 153';
  const donnees = { numero: '2026/153', fournisseur: { rib: '99438639017355887241', matricule_fiscal: null }, client: {}, facture_origine_numero: null };
  assert.deepEqual(alertesSource(verifierIdentifiantsDansSource(donnees, texte)), []);
});

test('la casse compte : « fa-2026-0001 » ne correspond pas à « FA-2026-0001 »', () => {
  const donnees = { numero: 'fa-2026-0001', fournisseur: {}, client: {} };
  assert.equal(verifierIdentifiantsDansSource(donnees, 'Facture FA-2026-0001')[0].present, false);
});

test('les identifiants nuls ne sont pas vérifiés', () => {
  const donnees = { numero: 'X1', fournisseur: { matricule_fiscal: null, rib: null }, client: { matricule_fiscal: null }, facture_origine_numero: null };
  assert.deepEqual(verifierIdentifiantsDansSource(donnees, 'X1').map((v) => v.champ), ['numero']);
});
