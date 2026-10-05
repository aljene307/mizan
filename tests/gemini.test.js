import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  PARAMETRES_GENERATION_GEMINI, construireRequeteGemini, urlGemini, classerErreur429,
  lireReponseGemini, attenteAvantNouvelEssai,
} from '../src/gemini.js';
import { validerExtraction } from '../src/validationExtraction.js';

const reponseReelle = JSON.parse(readFileSync('tests/fixtures/gemini-reponse-200.json', 'utf8'));
const schemaStrict = JSON.parse(readFileSync('src/schemas/extraction-facture.schema.json', 'utf8'));

test('paramètres de génération fixés explicitement (D-048)', () => {
  assert.deepEqual({ ...PARAMETRES_GENERATION_GEMINI }, {
    modele: 'gemini-3.5-flash-lite', temperature: 1.0, thinkingLevel: 'low',
    maxOutputTokens: 8192, candidateCount: 1, responseMimeType: 'application/json',
  });
  assert.ok(Object.isFrozen(PARAMETRES_GENERATION_GEMINI));
  assert.equal(urlGemini(), 'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent');
});

test('requête : instructions et document séparés, paramètres et schéma transmis', () => {
  const requete = construireRequeteGemini('INSTRUCTIONS', 'DOCUMENT', { type: 'object' });
  assert.equal(requete.systemInstruction.parts[0].text, 'INSTRUCTIONS');
  assert.equal(requete.contents[0].parts[0].text, 'DOCUMENT');
  assert.equal(requete.contents[0].role, 'user');
  assert.deepEqual(requete.generationConfig, {
    temperature: 1.0, maxOutputTokens: 8192, candidateCount: 1,
    thinkingConfig: { thinkingLevel: 'low' },
    responseMimeType: 'application/json', responseJsonSchema: { type: 'object' },
  });
});

test('réponse réelle de Gemini (200) : JSON lu, jetons et modèle relevés', () => {
  const r = lireReponseGemini(200, reponseReelle);
  assert.equal(r.code, 'ok');
  assert.equal(r.donnees.numero, 'TEST-0001');
  assert.equal(r.jetons_entree, 882);
  assert.equal(r.jetons_sortie, 357);
  assert.equal(r.jetons_reflexion, 0, 'thoughtsTokenCount absent : 0');
  assert.equal(r.modele, 'gemini-3.5-flash-lite');
  assert.equal(r.reessayer, false);
  // Le JSON renvoyé respecte le schéma strict (le RIB à 18 chiffres sera relevé par l'étape 4).
  assert.equal(validerExtraction(schemaStrict, r.donnees).valide, true);
});

test('la réponse est lue même si elle arrive sous forme de texte', () => {
  assert.equal(lireReponseGemini(200, JSON.stringify(reponseReelle)).code, 'ok');
});

test('réponses inexploitables : génération tronquée, bloquée, JSON illisible', () => {
  const tronquee = structuredClone(reponseReelle);
  tronquee.candidates[0].finishReason = 'MAX_TOKENS';
  assert.equal(lireReponseGemini(200, tronquee).code, 'reponse_illisible');
  assert.match(lireReponseGemini(200, tronquee).message, /MAX_TOKENS/);

  assert.equal(lireReponseGemini(200, { promptFeedback: { blockReason: 'SAFETY' } }).code, 'reponse_illisible');

  const illisible = structuredClone(reponseReelle);
  illisible.candidates[0].content.parts[0].text = '{"numero": "TEST';
  assert.equal(lireReponseGemini(200, illisible).code, 'reponse_illisible');
});

test('les parties « réflexion » éventuelles sont ignorées', () => {
  const avecReflexion = structuredClone(reponseReelle);
  avecReflexion.candidates[0].content.parts.unshift({ text: 'je réfléchis…', thought: true });
  assert.equal(lireReponseGemini(200, avecReflexion).code, 'ok');
});

// Formes de 429 SUPPOSÉES (aucun exemple officiel pour generateContent) : à
// confronter à la première vraie réponse 429.
const quotaMinute = {
  error: {
    code: 429, status: 'RESOURCE_EXHAUSTED', message: 'Quota exceeded for metric: generate_content_free_tier_requests',
    details: [
      { '@type': 'type.googleapis.com/google.rpc.QuotaFailure', violations: [{ quotaId: 'GenerateRequestsPerMinutePerProjectPerModel-FreeTier' }] },
      { '@type': 'type.googleapis.com/google.rpc.RetryInfo', retryDelay: '37s' },
    ],
  },
};
const quotaJour = structuredClone(quotaMinute);
quotaJour.error.details[0].violations[0].quotaId = 'GenerateRequestsPerDayPerProjectPerModel-FreeTier';

test('429 : quota par minute (on réessaie) ou quota journalier (on arrête le lot)', () => {
  assert.equal(classerErreur429(quotaMinute), 'quota_minute');
  assert.equal(classerErreur429(quotaJour), 'quota_journalier_epuise');
  assert.equal(classerErreur429({ error: { code: 'quota_exceeded' } }), 'quota_journalier_epuise');
  assert.equal(classerErreur429({ error: { code: 'rate_limit_exceeded' } }), 'quota_minute');

  const minute = lireReponseGemini(429, quotaMinute);
  assert.equal(minute.code, 'quota_minute_epuise');
  assert.equal(minute.reessayer, true);
  assert.equal(minute.delai_ms, 37000);
  const jour = lireReponseGemini(429, quotaJour);
  assert.equal(jour.code, 'quota_journalier_epuise');
  assert.equal(jour.reessayer, false);
});

test('autres erreurs : 5xx et absence de réponse réessayées, 4xx non', () => {
  assert.deepEqual([503, 500, 408].map((s) => lireReponseGemini(s, {}).reessayer), [true, true, true]);
  assert.deepEqual([400, 403, 404].map((s) => lireReponseGemini(s, {}).reessayer), [false, false, false]);
  assert.equal(lireReponseGemini(400, { error: { message: 'Invalid JSON payload' } }).message, 'HTTP 400 : Invalid JSON payload');
  const reseau = lireReponseGemini(null, null);
  assert.equal(reseau.code, 'erreur_fournisseur');
  assert.equal(reseau.reessayer, true);
});

test('attente avant nouvel essai : délai de Google ou exponentiel, plafonné à 60 s', () => {
  assert.deepEqual([1, 2, 3, 4].map((t) => attenteAvantNouvelEssai(t, null)), [10000, 20000, 40000, 60000]);
  assert.equal(attenteAvantNouvelEssai(1, 37000), 37000);
  assert.equal(attenteAvantNouvelEssai(3, 5000), 40000);
  assert.equal(attenteAvantNouvelEssai(1, 120000), 60000);
});
