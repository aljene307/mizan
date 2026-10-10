// Vérification automatique avant le dépôt d'un lot à évaluer (D-082, étape 5
// du protocole). Ne modifie rien. Chaque point affiche OK ou ÉCHEC ; le code
// de sortie est 1 si un point échoue.
// Usage : npm run verifier-avant-evaluation
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import pg from 'pg';
import { VERSION_CHAINE_EXTRACTION } from '../src/extractionWorkflow.js';

export const VERSION_ATTENDUE = 'D-053';
// Empreinte du prompt v1 figée par D-053 (début et fin, comme dans la décision).
export const EMPREINTE_PROMPT = { debut: '4efd7bb8', fin: '53909' };
// Workflows exécutés pendant l'évaluation : leur version dans n8n doit être celle du dépôt.
export const WORKFLOWS_EVALUES = ['extraction-llm.json', 'reception-extraction.json', 'controles.json'];
const EXTENSIONS_FACTURE = /\.(pdf|jpe?g|png|xml)$/i;

/**
 * Chemins où n8n diffère du dépôt. n8n n'enregistre pas les valeurs égales à
 * leur valeur par défaut (« operation: read », « unit: seconds »…) : une clé
 * absente dans n8n est tolérée ; une clé présente doit avoir la même valeur, et
 * n8n ne doit rien avoir que le dépôt n'a pas. Le code des nœuds Code n'est
 * jamais une valeur par défaut : il est donc comparé strictement.
 */
export function differences(n8n, depot, chemin = '') {
  if (n8n === null || typeof n8n !== 'object' || depot === null || typeof depot !== 'object' || Array.isArray(n8n) !== Array.isArray(depot)) {
    return JSON.stringify(n8n) === JSON.stringify(depot) ? [] : [chemin || '(racine)'];
  }
  if (Array.isArray(n8n) && n8n.length !== depot.length) return [`${chemin} (longueur)`];
  return Object.keys(n8n).flatMap((k) => (k in depot ? differences(n8n[k], depot[k], `${chemin}.${k}`) : [`${chemin}.${k} (absent du dépôt)`]));
}

/**
 * Nœuds dont les paramètres diffèrent entre le dépôt et n8n (nom du nœud → raison).
 * @param {object[]} depot nœuds du fichier du dépôt ; @param {object[]} n8n nœuds enregistrés dans n8n
 */
export function ecartsNoeuds(depot, n8n) {
  const parNom = new Map(n8n.map((n) => [n.name, n]));
  const ecarts = [];
  for (const n of depot) {
    const d = parNom.get(n.name);
    if (!d) { ecarts.push(`${n.name} : absent de n8n`); continue; }
    // Appel d'un sous-workflow : l'identifiant est propre à l'installation (choisi à
    // l'import) ; il est vérifié à part (bon sous-workflow), pas comparé au dépôt.
    const propre = n.type === 'n8n-nodes-base.executeWorkflow' ? ['workflowId', 'workflowInputs'] : [];
    const sans = (p) => Object.fromEntries(Object.entries(p ?? {}).filter(([k]) => !propre.includes(k)));
    const diff = differences(sans(d.parameters), sans(n.parameters));
    if (diff.length) ecarts.push(`${n.name} : paramètres différents (${diff.join(', ')})`);
  }
  for (const d of n8n) if (!depot.some((n) => n.name === d.name)) ecarts.push(`${d.name} : présent dans n8n seulement`);
  return ecarts;
}

async function requete(base, sql, valeurs = []) {
  const c = new pg.Client({ host: 'localhost', port: 5432, user: process.env.POSTGRES_USER, password: process.env.POSTGRES_PASSWORD, database: base });
  await c.connect();
  try { return (await c.query(sql, valeurs)).rows; } finally { await c.end(); }
}

async function principal() {
  if (existsSync('.env')) process.loadEnvFile('.env');
  const base = process.env.MIZAN_DB ?? 'mizan';
  const resultats = [];
  const verifier = async (libelle, controle) => {
    try {
      const detail = await controle();
      resultats.push({ ok: !detail, libelle, detail });
    } catch (e) {
      resultats.push({ ok: false, libelle, detail: e.message });
    }
  };

  await verifier(`Configuration d'extraction : version de chaîne ${VERSION_ATTENDUE}`, () =>
    (VERSION_CHAINE_EXTRACTION === VERSION_ATTENDUE ? null : `version du code : ${VERSION_CHAINE_EXTRACTION}`));
  await verifier('Prompt v1, empreinte figée par D-053', () => {
    const versions = JSON.parse(readFileSync('src/prompts-versions.json', 'utf8'));
    const v1 = JSON.stringify(versions).match(/[0-9a-f]{64}/g)?.find((h) => h.startsWith(EMPREINTE_PROMPT.debut));
    return v1 && v1.endsWith(EMPREINTE_PROMPT.fin) ? null : 'empreinte du prompt v1 introuvable ou différente';
  });
  await verifier('Code du dépôt commité (aucune modification en cours)', () => {
    const r = spawnSync('git', ['status', '--porcelain', '--untracked-files=no'], { encoding: 'utf8' });
    return r.stdout.trim() ? `fichiers modifiés :\n${r.stdout.trim()}` : null;
  });
  await verifier('Workflows évalués : code chargé dans n8n identique au dépôt', async () => {
    const ecarts = [];
    for (const f of WORKFLOWS_EVALUES) {
      const depot = JSON.parse(readFileSync(`workflows/${f}`, 'utf8'));
      const enN8n = await requete(process.env.POSTGRES_DB, 'SELECT nodes FROM workflow_entity WHERE name = $1 AND NOT "isArchived"', [depot.name]);
      if (enN8n.length !== 1) { ecarts.push(`${depot.name} : ${enN8n.length} version(s) dans n8n (une seule attendue)`); continue; }
      ecarts.push(...ecartsNoeuds(depot.nodes, enN8n[0].nodes).map((x) => `${depot.name} — ${x}`));
    }
    return ecarts.length ? ecarts.join('\n') : null;
  });
  await verifier('Le workflow principal appelle le bon sous-workflow d\'extraction', async () => {
    const [principalN8n] = await requete(process.env.POSTGRES_DB,
      `SELECT n -> 'parameters' -> 'workflowId' ->> 'value' AS id FROM workflow_entity w, json_array_elements(w.nodes) n
       WHERE w.name = 'Mizan – Réception et extraction' AND NOT w."isArchived" AND n ->> 'type' = 'n8n-nodes-base.executeWorkflow'`);
    const sous = await requete(process.env.POSTGRES_DB, `SELECT id FROM workflow_entity WHERE name = 'Mizan – Extraction LLM (Gemini)' AND NOT "isArchived"`);
    return principalN8n && sous.length === 1 && principalN8n.id === sous[0].id ? null
      : `appelle « ${principalN8n?.id ?? 'rien'} », sous-workflow « ${sous.map((s) => s.id).join(', ') || 'absent'} »`;
  });
  await verifier('Aucun workflow Mizan publié dans n8n', async () => {
    const publies = await requete(process.env.POSTGRES_DB, `SELECT name FROM workflow_entity WHERE active AND NOT "isArchived" AND name LIKE 'Mizan%'`);
    return publies.length ? `publiés : ${publies.map((p) => p.name).join(', ')}` : null;
  });
  await verifier('Credentials rattachés dans n8n conformes au dépôt', () => {
    const r = spawnSync(process.execPath, ['scripts/verifier-credentials-n8n.js'], { encoding: 'utf8' });
    return r.status === 0 ? null : r.stdout.trim() || r.stderr.trim();
  });
  await verifier(`Base « ${base} » vierge : aucune facture, aucune extraction, aucun relevé`, async () => {
    const [x] = await requete(base, `SELECT (SELECT count(*) FROM factures)::int AS f, (SELECT count(*) FROM extractions)::int AS e,
      (SELECT count(*) FROM releves_bancaires)::int AS r`);
    return x.f + x.e + x.r ? `${x.f} facture(s), ${x.e} extraction(s), ${x.r} relevé(s)` : null;
  });
  await verifier('Référentiel chargé, 22 règles de contrôle actives', async () => {
    const [x] = await requete(base, `SELECT (SELECT count(*) FROM fournisseurs)::int AS f, (SELECT count(*) FROM regles_controle WHERE actif)::int AS r`);
    return x.f > 0 && x.r === 22 ? null : `${x.f} fournisseur(s), ${x.r} règle(s) active(s)`;
  });
  await verifier('Toutes les migrations appliquées', async () => {
    const appliquees = new Set((await requete(base, 'SELECT version FROM schema_migrations')).map((r) => r.version));
    const manquantes = readdirSync('db/migrations').map((f) => f.split('_')[0]).filter((v) => !appliquees.has(v));
    return manquantes.length ? `non appliquées : ${manquantes.join(', ')}` : null;
  });
  await verifier('data/entrant/ ne contient aucune facture', () => {
    const fichiers = readdirSync('data/entrant', { withFileTypes: true }).filter((d) => d.isFile() && EXTENSIONS_FACTURE.test(d.name));
    return fichiers.length ? `${fichiers.length} fichier(s) : ${fichiers.slice(0, 5).map((d) => d.name).join(', ')}…` : null;
  });

  for (const r of resultats) {
    console.log(`${r.ok ? 'OK    ' : 'ÉCHEC '} ${r.libelle}`);
    if (!r.ok) console.log(r.detail.split('\n').map((x) => `         ${x}`).join('\n'));
  }
  console.log('À vérifier à la main : quota restant de gemini-3.5-flash-lite dans AI Studio (D-036) ; aucune question /q ce jour-là.');
  if (resultats.some((r) => !r.ok)) process.exitCode = 1;
}

if (process.argv[1]?.endsWith('verifier-avant-evaluation.js')) {
  principal().catch((e) => { console.error(e.message); process.exitCode = 1; });
}
