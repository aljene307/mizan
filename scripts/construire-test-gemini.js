// Construit workflows/test-gemini.json à partir des modules de src/ (prompt,
// schéma simplifié, paramètres de génération) : le test envoie exactement la
// requête que fera le sous-workflow LLM. Une seule requête de génération.
// Usage : node scripts/construire-test-gemini.js
import { readFileSync, writeFileSync } from 'node:fs';
import { MOTS_CLES_GEMINI, simplifierSchema } from '../src/schemaFournisseur.js';
import { INSTRUCTIONS_SYSTEME, construireMessageDocument } from '../src/promptExtraction.js';
import { PARAMETRES_GENERATION_GEMINI, construireRequeteGemini, urlGemini } from '../src/gemini.js';

const schema = simplifierSchema(JSON.parse(readFileSync('src/schemas/extraction-facture.schema.json', 'utf8')), MOTS_CLES_GEMINI);
// Facture inventée, hors des deux lots. Le RIB complet (20 chiffres, clé valide).
const texte = [
  'Papeterie Exemple Test', 'MF : 9900000K/A/M/000', 'FACTURE N° TEST-0001',
  'Date : 01/03/2026 - Échéance : 31/03/2026', 'Client : Société Démo Mizan SARL',
  'Ramette papier A4 | 10 | 12,500 | 19 % | 125,000', 'Total HT 125,000', 'TVA 19 % 23,750',
  'Timbre fiscal 1,000', 'Total TTC 149,750', 'RIB : 99 001 0000000000001 65',
].join('\n');
const corps = construireRequeteGemini(INSTRUCTIONS_SYSTEME, construireMessageDocument(texte), schema);
const options = { response: { response: { fullResponse: true, neverError: true } }, timeout: 60000 };
const credentials = { googlePalmApi: { id: '', name: 'Gemini Mizan' } };
const urlModele = urlGemini().replace(':generateContent', '');

const workflow = {
  name: 'Mizan – test Gemini (une requête)',
  nodes: [
    { parameters: {}, id: '6d1c5f0e-0001-4a00-9000-000000000001', name: 'Lancer le test', type: 'n8n-nodes-base.manualTrigger', typeVersion: 1, position: [0, 0] },
    {
      parameters: { url: urlModele, authentication: 'predefinedCredentialType', nodeCredentialType: 'googlePalmApi', options },
      id: '6d1c5f0e-0002-4a00-9000-000000000002', name: 'Le modèle existe-t-il ?', type: 'n8n-nodes-base.httpRequest', typeVersion: 4.5, position: [240, 0], credentials,
    },
    {
      parameters: {
        method: 'POST', url: urlGemini(), authentication: 'predefinedCredentialType', nodeCredentialType: 'googlePalmApi',
        sendBody: true, specifyBody: 'json', jsonBody: JSON.stringify(corps, null, 2), options,
      },
      id: '6d1c5f0e-0003-4a00-9000-000000000003', name: 'Extraction de test', type: 'n8n-nodes-base.httpRequest', typeVersion: 4.5, position: [480, 0], credentials,
    },
  ],
  connections: {
    'Lancer le test': { main: [[{ node: 'Le modèle existe-t-il ?', type: 'main', index: 0 }]] },
    'Le modèle existe-t-il ?': { main: [[{ node: 'Extraction de test', type: 'main', index: 0 }]] },
  },
  settings: { executionOrder: 'v1' },
  pinData: {},
};
writeFileSync('workflows/test-gemini.json', `${JSON.stringify(workflow, null, 2)}\n`);
console.log(`workflows/test-gemini.json reconstruit (modèle ${PARAMETRES_GENERATION_GEMINI.modele}, thinkingLevel ${PARAMETRES_GENERATION_GEMINI.thinkingLevel}, température ${PARAMETRES_GENERATION_GEMINI.temperature}).`);
