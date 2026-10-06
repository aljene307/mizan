// Logique des nœuds Code des deux workflows (sous-workflow LLM et workflow
// principal), testée avec les vraies réponses de Gemini du 2026-10-05.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { MAX_TENTATIVES_LLM, preparerAppel, traiterReponse } from '../src/sousWorkflowLlm.js';
import {
  VERSION_CHAINE_EXTRACTION, texteSuffisant, texteAExtraire, payloadExtraction,
  payloadReutilisation, payloadEchec, messageErreur,
} from '../src/extractionWorkflow.js';
import { PARAMETRES_GENERATION_GEMINI, construireRequeteGemini, urlGemini, lireReponseGemini, attenteAvantNouvelEssai } from '../src/gemini.js';
import { INSTRUCTIONS_SYSTEME, construireMessageDocument, VERSION_PROMPT } from '../src/promptExtraction.js';
import { validerExtraction } from '../src/validationExtraction.js';
import { verifierIdentifiantsDansSource, alertesSource } from '../src/verificationSource.js';
import { corrigerExtraction } from '../src/correctionsCode.js';
import { ribValide } from '../src/rib.js';
import { formeCourteMatricule } from '../src/matricule.js';

const lire = (chemin) => JSON.parse(readFileSync(chemin, 'utf8'));
const versions = lire('src/prompts-versions.json');
const schemaStrict = lire('src/schemas/extraction-facture.schema.json');
const reponseOk = lire('tests/fixtures/gemini-reponse-200.json');
const reponseRibErrone = lire('tests/fixtures/gemini-reponse-200-rib-errone.json');
const depsAppel = {
  versionPrompt: VERSION_PROMPT, empreintes: versions, instructions: INSTRUCTIONS_SYSTEME,
  construireMessageDocument, schemaFournisseur: { type: 'object' }, parametres: PARAMETRES_GENERATION_GEMINI,
  construireRequete: construireRequeteGemini, url: urlGemini(),
};
const depsReponse = { lireReponse: lireReponseGemini, attente: attenteAvantNouvelEssai, fournisseur: 'google' };
const depsControle = { corrigerExtraction, ribValide, formeCourteMatricule, validerExtraction, verifierIdentifiantsDansSource, alertesSource };

// --- Sous-workflow LLM ----------------------------------------------------------

test('contrat d\'entrée : texte et version de prompt obligatoires', () => {
  assert.throws(() => preparerAppel({ version_prompt: 'v1' }, depsAppel), /« texte » manquant/);
  assert.throws(() => preparerAppel({ texte: '  ', version_prompt: 'v1' }, depsAppel), /« texte » manquant/);
  assert.throws(() => preparerAppel({ texte: 'x', version_prompt: 'v9' }, depsAppel), /version de prompt « v9 » inconnue/);
});

test('préparation : requête construite, prompt identifié par version et empreinte', () => {
  const appel = preparerAppel({ texte: 'Facture n° 1', version_prompt: 'v1' }, depsAppel);
  assert.equal(appel.version_prompt, 'v1');
  assert.equal(appel.empreinte_prompt, versions.v1);
  assert.equal(appel.url, urlGemini());
  assert.match(appel.requete.contents[0].parts[0].text, /<document_non_fiable>\nFacture n° 1\n<\/document_non_fiable>/);
  assert.deepEqual(appel.parametres_generation, { ...PARAMETRES_GENERATION_GEMINI });
});

test('réponse 200 : contrat « ok » avec données, jetons et durée', () => {
  const essai = { ...preparerAppel({ texte: 'x', version_prompt: 'v1' }, depsAppel), debut_essai: 1000 };
  const r = traiterReponse(essai, { statusCode: 200, body: reponseOk }, 1, 2421, depsReponse);
  assert.equal(r.reessayer, false);
  assert.equal(r.contrat.code_resultat, 'ok');
  assert.equal(r.contrat.donnees.numero, 'TEST-0001');
  assert.equal(r.contrat.duree_ms, 1421);
  assert.equal(r.contrat.jetons_entree, 882);
  assert.equal(r.contrat.modele, 'gemini-3.5-flash-lite');
  assert.equal(r.contrat.tentatives, 1);
  assert.ok(!('debut_essai' in r));
});

test('429 par minute : on réessaie, puis on abandonne après 3 tentatives', () => {
  const quota = { error: { code: 429, message: 'Quota exceeded', details: [{ retryDelay: '20s' }] } };
  const essai = { ...preparerAppel({ texte: 'x', version_prompt: 'v1' }, depsAppel), debut_essai: 0, cumul_ms: 500 };
  const premier = traiterReponse(essai, { statusCode: 429, body: quota }, 1, 100, depsReponse);
  assert.equal(premier.reessayer, true);
  assert.equal(premier.attente_ms, 20000);
  assert.equal(premier.cumul_ms, 600, 'la durée cumule les tentatives');
  const dernier = traiterReponse({ ...premier, debut_essai: 0 }, { statusCode: 429, body: quota }, MAX_TENTATIVES_LLM, 100, depsReponse);
  assert.equal(dernier.reessayer, false);
  assert.equal(dernier.contrat.code_resultat, 'quota_minute_epuise');
  assert.equal(dernier.contrat.tentatives, 3);
});

test('quota journalier, panne réseau, 400 : bons codes de résultat', () => {
  const essai = { ...preparerAppel({ texte: 'x', version_prompt: 'v1' }, depsAppel), debut_essai: 0 };
  const jour = traiterReponse(essai, { statusCode: 429, body: { error: { code: 'quota_exceeded' } } }, 1, 0, depsReponse);
  assert.deepEqual([jour.reessayer, jour.contrat.code_resultat], [false, 'quota_journalier_epuise']);
  const reseau = traiterReponse(essai, { error: { message: 'ECONNRESET' } }, 1, 0, depsReponse);
  assert.deepEqual([reseau.reessayer, reseau.contrat.code_resultat], [true, 'erreur_fournisseur']);
  const requeteInvalide = traiterReponse(essai, { statusCode: 400, body: { error: { message: 'Invalid' } } }, 1, 0, depsReponse);
  assert.deepEqual([requeteInvalide.reessayer, requeteInvalide.contrat.code_resultat], [false, 'erreur_fournisseur']);
});

// --- Workflow principal ----------------------------------------------------------

const reservation = { facture_id: 42, fichier_sha256: 'a'.repeat(64), format_source: 'pdf' };
const texteSource = ['MF : 9900000K/A/M/000', 'FACTURE N° TEST-0001', 'RIB : 99 001 0000000000001 65'].join('\n');
const contratDe = (corps) => traiterReponse(
  { ...preparerAppel({ texte: texteSource, version_prompt: 'v1' }, depsAppel), debut_essai: 0 },
  { statusCode: 200, body: corps }, 1, 1300, depsReponse,
).contrat;

test('texte à extraire : PDF ou OCR, et seuil du PDF scanné', () => {
  assert.deepEqual(texteAExtraire({ text: 'abc' }, 'v1'), { texte: 'abc', methode_lecture: 'texte_pdf', duree_lecture_ms: null, version_prompt: 'v1' });
  assert.deepEqual(texteAExtraire({ body: { texte: 'xyz', duree_ms: 610 } }, 'v1').methode_lecture, 'ocr');
  assert.throws(() => texteAExtraire({}, 'v1'), /aucun texte lu/);
  assert.equal(texteSuffisant(' \n\f '), false);
  assert.equal(texteSuffisant('x'.repeat(49)), false);
  const pdfReel = readFileSync('data/synthetic/dev/verite/D007.json', 'utf8');
  assert.equal(texteSuffisant(pdfReel), true);
});

test('extraction valide sans alerte (première réponse réelle)', () => {
  const r = payloadExtraction({ reservation, lecture: { texte: texteSource, methode_lecture: 'texte_pdf', duree_lecture_ms: null },
    contrat: contratDe(reponseOk), ribsReferentiel: {}, schema: schemaStrict, executionId: 'e1' }, depsControle);
  assert.equal(r.arret_quota, false);
  assert.equal(r.appel_llm, true);
  assert.equal(r.payload.resultat, 'valide');
  assert.equal(r.payload.facture_id, 42);
  assert.equal(r.payload.duree_llm_ms, 1300);
  assert.equal(r.payload.texte_source, texteSource, 'texte transmis au LLM conservé (D-051)');
  // La première réponse avait 18 chiffres pour un RIB de test qui n'en avait que 18 (« xx ») :
  // avec le RIB corrigé à 20 chiffres, elle est signalée.
  assert.deepEqual(r.payload.alertes_source, ['fournisseur.rib « 990010000000000001 » absent du texte source']);
});

test('corrections par le code (D-053) : sortie brute conservée, RIB proposé (fournisseur absent du référentiel)', () => {
  const r = payloadExtraction({ reservation, lecture: { texte: texteSource, methode_lecture: 'texte_pdf' },
    contrat: contratDe(reponseOk), ribsReferentiel: {}, schema: schemaStrict, executionId: 'e1b' }, depsControle);
  assert.equal(r.payload.donnees_brutes.fournisseur.rib, '990010000000000001', 'sortie brute du modèle');
  assert.equal(r.payload.donnees.fournisseur.rib, '990010000000000001', 'jamais remplacé sans le référentiel');
  assert.deepEqual(r.payload.propositions.map((p) => [p.valeur, p.rib_referentiel]), [['99001000000000000165', null]]);
  assert.deepEqual(r.payload.signalements_code, []);
});

test('corrections par le code : RIB du texte identique au référentiel → rempli, plus d\'alerte', () => {
  const r = payloadExtraction({ reservation, lecture: { texte: texteSource, methode_lecture: 'texte_pdf' },
    contrat: contratDe(reponseOk), ribsReferentiel: { '9900000K': '99001000000000000165' }, schema: schemaStrict, executionId: 'e1c' }, depsControle);
  assert.equal(r.payload.donnees.fournisseur.rib, '99001000000000000165');
  assert.equal(r.payload.donnees_brutes.fournisseur.rib, '990010000000000001');
  assert.equal(r.payload.corrections_code.length, 1);
  assert.deepEqual(r.payload.alertes_source, [], 'le contrôle D-047 porte sur les données corrigées');
});

test('référentiel illisible : aucun RIB rempli, extraction signalée', () => {
  const r = payloadExtraction({ reservation, lecture: { texte: texteSource, methode_lecture: 'texte_pdf' },
    contrat: contratDe(reponseOk), ribsReferentiel: null, schema: schemaStrict, executionId: 'e1d' }, depsControle);
  assert.equal(r.payload.donnees.fournisseur.rib, '990010000000000001');
  assert.equal(r.payload.propositions.length, 1);
  assert.match(r.payload.signalements_code.at(-1), /référentiel des RIB illisible/);
});

test('extraction valide avec alerte (seconde réponse réelle : un zéro ajouté au RIB)', () => {
  const r = payloadExtraction({ reservation, lecture: { texte: texteSource, methode_lecture: 'ocr', duree_lecture_ms: 600 },
    contrat: contratDe(reponseRibErrone), ribsReferentiel: {}, schema: schemaStrict, executionId: 'e2' }, depsControle);
  assert.equal(r.payload.resultat, 'valide', 'le schéma ne voit pas l\'erreur…');
  assert.equal(r.payload.alertes_source.length, 1, '…le contrôle des identifiants, si');
  assert.equal(r.payload.verifications_source.find((v) => v.champ === 'numero').present, true);
});

test('extraction invalide (schéma) : enregistrée comme « invalide », sans vérification', () => {
  const corps = structuredClone(reponseOk);
  corps.candidates[0].content.parts[0].text = corps.candidates[0].content.parts[0].text.replace('"TND"', '"tnd"');
  const r = payloadExtraction({ reservation, lecture: { texte: texteSource, methode_lecture: 'texte_pdf' },
    contrat: contratDe(corps), ribsReferentiel: {}, schema: schemaStrict, executionId: 'e3' }, depsControle);
  assert.equal(r.payload.resultat, 'invalide');
  assert.ok(r.payload.erreurs.some((e) => e.startsWith('/devise')));
  assert.deepEqual(r.payload.verifications_source, []);
});

test('quota journalier : arrêt du lot, aucun enregistrement d\'extraction', () => {
  const contrat = { code_resultat: 'quota_journalier_epuise', message_erreur: 'quota' };
  const r = payloadExtraction({ reservation, lecture: {}, contrat, ribsReferentiel: {}, schema: schemaStrict, executionId: 'e4' }, depsControle);
  assert.deepEqual(r, { arret_quota: true, appel_llm: true, message: 'quota', payload: null });
});

test('erreur du fournisseur : extraction en erreur, le lot continue', () => {
  const contrat = { code_resultat: 'erreur_fournisseur', message_erreur: 'HTTP 503 : overloaded', tentatives: 3 };
  const r = payloadExtraction({ reservation, lecture: { methode_lecture: 'ocr' }, contrat, ribsReferentiel: {}, schema: schemaStrict, executionId: 'e5' }, depsControle);
  assert.equal(r.arret_quota, false);
  assert.deepEqual([r.payload.resultat, r.payload.code_resultat, r.payload.erreurs], ['erreur', 'erreur_fournisseur', ['HTTP 503 : overloaded']]);
});

test('réutilisation et échecs hors LLM', () => {
  const reutil = payloadReutilisation(reservation, { extraction_id: 7, donnees: { numero: 'X' }, methode_lecture: 'ocr' }, 'e6');
  assert.deepEqual([reutil.appel_llm, reutil.payload.resultat, reutil.payload.reutilise_de], [false, 'reutilisee', 7]);
  const echec = payloadEchec(reservation, 'erreur_lecture', 'fichier introuvable', 'e7', false);
  assert.deepEqual([echec.payload.resultat, echec.payload.code_resultat, echec.appel_llm], ['erreur', 'erreur_lecture', false]);
  assert.equal(echec.payload.texte_source, null, 'aucun texte lu');
  const panneLlm = payloadEchec(reservation, 'erreur_fournisseur', 'HTTP 503', 'e8', true, 'FACTURE N° 1');
  assert.equal(panneLlm.payload.texte_source, 'FACTURE N° 1', 'texte déjà lu conservé');
  assert.equal(messageErreur({ error: { message: 'ENOENT' } }), 'ENOENT');
  assert.equal(messageErreur({ error: 'texte brut' }), 'texte brut');
});

test('version de la chaîne d\'extraction (D-059) : enregistrée avec chaque extraction, réussie ou non', () => {
  const r = payloadExtraction({ reservation, lecture: { texte: texteSource, methode_lecture: 'texte_pdf' },
    contrat: contratDe(reponseOk), ribsReferentiel: {}, schema: schemaStrict, executionId: 'e9' }, depsControle);
  assert.equal(r.payload.version_chaine, VERSION_CHAINE_EXTRACTION);
  assert.equal(VERSION_CHAINE_EXTRACTION, 'D-053', 'configuration figée par D-053');
  assert.equal(payloadEchec(reservation, 'erreur_lecture', 'x', 'e10', false).payload.version_chaine, VERSION_CHAINE_EXTRACTION);
});
