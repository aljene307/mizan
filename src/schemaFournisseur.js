// Dérive, du schéma strict, la version simplifiée envoyée au fournisseur de
// LLM (D-037) : on ne garde que les mots-clés que le fournisseur accepte. Le
// schéma strict complet est vérifié ensuite par src/validationExtraction.js.

// Mots-clés acceptés par la sortie structurée de Gemini (documentation
// « Structured outputs » consultée le 2026-10-05).
const MOTS_CLES_GEMINI = [
  'type', 'properties', 'required', 'additionalProperties', 'enum', 'format',
  'minimum', 'maximum', 'items', 'minItems', 'maxItems', 'title', 'description',
];

/**
 * Copie récursive du schéma en ne gardant que les mots-clés autorisés.
 * Les clés de « properties » sont des noms de champs, pas des mots-clés :
 * elles sont toutes conservées.
 * @param {object} schema
 * @param {string[]} motsClesAutorises
 * @returns {object}
 */
function simplifierSchema(schema, motsClesAutorises) {
  const autorises = new Set(motsClesAutorises);
  const simplifier = (noeud) => {
    const resultat = {};
    for (const [cle, valeur] of Object.entries(noeud)) {
      if (!autorises.has(cle)) continue;
      if (cle === 'properties') {
        resultat.properties = Object.fromEntries(
          Object.entries(valeur).map(([nom, sousSchema]) => [nom, simplifier(sousSchema)]),
        );
      } else if (cle === 'items') {
        resultat.items = simplifier(valeur);
      } else {
        resultat[cle] = valeur;
      }
    }
    return resultat;
  };
  return simplifier(schema);
}

export { MOTS_CLES_GEMINI, simplifierSchema };
