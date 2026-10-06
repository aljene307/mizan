// Éléments partagés par eval/mesurer.js et eval/analyser-mesure.js (D-052).
import { MOTS_CLES_GEMINI, simplifierSchema } from '../src/schemaFournisseur.js';

export const DOSSIER_MESURE = 'eval/resultats/mesure-2026-10-06';
export const FICHIER_APPELS = `${DOSSIER_MESURE}/appels.jsonl`;

// 2 prompts × 2 schémas (D-052).
export const CONFIGURATIONS = Object.freeze([
  { id: 'v1-libre', prompt: 'v1', devise: 'libre' },
  { id: 'v1-liste', prompt: 'v1', devise: 'liste' },
  { id: 'v2-libre', prompt: 'v2', devise: 'libre' },
  { id: 'v2-liste', prompt: 'v2', devise: 'liste' },
]);

// Liste fermée avec une valeur AUTRE, que le schéma strict rejette (parade D-052).
export const DEVISES_LISTE = Object.freeze(['TND', 'EUR', 'USD', 'AUTRE']);

// Documents de la mesure de stabilité (lot dev) : injection (D001), RIB non
// extraits (D011, D023, D044), RIB abîmé par l'OCR (D050), devise « DT »
// (D015, D019), entités HTML (D018), deux factures sans difficulté (D010, D020).
export const DOCUMENTS_STABILITE = Object.freeze(['D001', 'D010', 'D011', 'D015', 'D018', 'D019', 'D020', 'D023', 'D044', 'D050']);

/** Schéma envoyé à Gemini pour une configuration. */
export function schemaPourConfiguration(schemaStrict, configuration) {
  const schema = simplifierSchema(schemaStrict, MOTS_CLES_GEMINI);
  if (configuration.devise === 'liste') {
    schema.properties.devise = { type: 'string', enum: [...DEVISES_LISTE] };
  }
  return schema;
}

// Copies d'essai du workflow (« D023-essai.pdf » : un octet ajouté pour changer
// l'empreinte) : jamais comptées dans une évaluation ni une mesure (D-054).
const COPIE_ESSAI = /-essai\.[^./]+$/i;
export const estCopieEssai = (fichierNom) => COPIE_ESSAI.test(String(fichierNom ?? ''));

/** Clé identifiant un appel, pour la reprise après interruption. */
export const cleAppel = (a) => `${a.configuration}|${a.document}|${a.passage}`;
