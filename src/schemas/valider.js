// Validation JSON Schema (draft 2020-12) des extractions et des vérités terrain.
import { readFileSync } from 'node:fs';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const lire = (nom) => JSON.parse(readFileSync(new URL(nom, import.meta.url), 'utf8'));

const ajv = new Ajv2020({ allErrors: true, strict: true });
addFormats(ajv);
ajv.addSchema(lire('./extraction-facture.schema.json'));
ajv.addSchema(lire('./verite-terrain.schema.json'));

/**
 * Valide un objet ; renvoie la liste des erreurs (vide si valide).
 * @param {'extraction'|'verite'} type
 * @param {unknown} donnees
 * @returns {string[]}
 */
export function valider(type, donnees) {
  const id = type === 'extraction'
    ? 'https://mizan.example/schemas/extraction-facture.schema.json'
    : 'https://mizan.example/schemas/verite-terrain.schema.json';
  const validateur = ajv.getSchema(id);
  if (validateur(donnees)) return [];
  return validateur.errors.map((e) => `${e.instancePath || '/'} ${e.message}`);
}
