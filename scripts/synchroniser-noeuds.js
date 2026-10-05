// Recopie le code de src/ dans les nœuds Code des workflows exportés (D-041).
// Dans un nœud Code, une région générée est encadrée par deux marqueurs :
//     // <<< src/validationExtraction.js
//     ...source recopiée, sans les « export »...
//     // >>>
// Pour un fichier JSON, le marqueur nomme la constante à créer :
//     // <<< src/schemas/extraction-facture.schema.json as SCHEMA_EXTRACTION
// Usage : npm run synchroniser-noeuds            (met à jour workflows/*.json)
//         npm run synchroniser-noeuds -- --verifier  (échoue si une région diffère)
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const TYPE_NOEUD_CODE = 'n8n-nodes-base.code';
const REGION = /(\/\/ <<< (\S+)(?: as ([A-Z_][A-Z0-9_]*))?\n)([\s\S]*?)(\/\/ >>>)/g;

/**
 * Transforme un fichier de src/ en code utilisable dans un nœud Code :
 * JavaScript sans « export » (un nœud Code ne peut pas importer de module),
 * ou constante pour un fichier JSON.
 * @param {string} chemin chemin relatif à la racine du dépôt
 * @param {string|undefined} nomConstante obligatoire pour un fichier JSON
 * @param {(chemin: string) => string} lire
 * @returns {string}
 */
export function transformerSource(chemin, nomConstante, lire) {
  const contenu = lire(chemin);
  if (chemin.endsWith('.json')) {
    if (!nomConstante) throw new Error(`${chemin} : un fichier JSON exige « as NOM_CONSTANTE »`);
    return `const ${nomConstante} = ${JSON.stringify(JSON.parse(contenu), null, 2)};\n`;
  }
  if (/^\s*import\s/m.test(contenu)) {
    throw new Error(`${chemin} : un nœud Code ne peut pas importer de module ; le fichier doit être autonome`);
  }
  return `${contenu
    .replace(/^export\s*\{[^}]*\};?\s*$/gm, '')
    .replace(/^export\s+(?=(?:async\s+)?function|const|let|class)/gm, '')
    .trimEnd()}\n`;
}

/**
 * Remplace le contenu de chaque région générée d'un code par la source à jour.
 * @returns {{code: string, regions: {chemin: string, aJour: boolean}[]}}
 */
export function synchroniserCode(code, lire) {
  const regions = [];
  const nouveau = code.replace(REGION, (_, ouverture, chemin, constante, actuel, fermeture) => {
    const attendu = transformerSource(chemin, constante, lire);
    regions.push({ chemin, aJour: actuel === attendu });
    return `${ouverture}${attendu}${fermeture}`;
  });
  return { code: nouveau, regions };
}

/**
 * Synchronise tous les nœuds Code d'un workflow exporté (objet JSON).
 * @returns {{workflow: object, regions: {noeud: string, chemin: string, aJour: boolean}[]}}
 */
export function synchroniserWorkflow(workflow, lire) {
  const copie = structuredClone(workflow);
  const regions = [];
  for (const noeud of copie.nodes ?? []) {
    if (noeud.type !== TYPE_NOEUD_CODE || typeof noeud.parameters?.jsCode !== 'string') continue;
    const resultat = synchroniserCode(noeud.parameters.jsCode, lire);
    noeud.parameters.jsCode = resultat.code;
    regions.push(...resultat.regions.map((r) => ({ noeud: noeud.name, ...r })));
  }
  return { workflow: copie, regions };
}

function principal() {
  const verifier = process.argv.includes('--verifier');
  const lire = (chemin) => readFileSync(chemin, 'utf8');
  let ecarts = 0;
  for (const fichier of readdirSync('workflows').filter((f) => f.endsWith('.json'))) {
    const chemin = join('workflows', fichier);
    const original = JSON.parse(lire(chemin));
    const { workflow, regions } = synchroniserWorkflow(original, lire);
    for (const r of regions.filter((x) => !x.aJour)) {
      ecarts += 1;
      console.log(`${verifier ? 'Écart' : 'Mis à jour'} : ${fichier} › ${r.noeud} › ${r.chemin}`);
    }
    if (!verifier && regions.some((r) => !r.aJour)) writeFileSync(chemin, `${JSON.stringify(workflow, null, 2)}\n`);
  }
  if (verifier && ecarts) process.exit(1);
  console.log(ecarts ? `${ecarts} région(s) ${verifier ? 'désynchronisée(s)' : 'mise(s) à jour'}.` : 'Tout est synchronisé.');
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) principal();
