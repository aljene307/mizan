// Contrôle des credentials rattachés dans n8n (incident du 2026-10-09 : au
// réimport, n8n a rattaché « PostgreSQL Mizan (lecture) » aux nœuds de
// « Réponses Telegram », qui écrivent). Pour chaque workflow du dépôt présent
// dans n8n, version publiée ET brouillon : chaque nœud doit utiliser le
// credential prévu par le fichier du dépôt (par son nom). Lecture seule de la
// base interne de n8n ; la colonne des secrets chiffrés n'est jamais lue.
// Réglages (D-086) : n8n ne reprend pas les réglages du fichier à l'import ;
// « Mizan – Erreurs » est publié (n8n n'exécute que la version publiée d'un
// workflow d'erreur) et ne désigne aucun workflow d'erreur (il ne doit jamais
// se déclencher lui-même) ; chaque autre workflow publié le désigne comme
// workflow d'erreur et porte les réglages d'exécution du dépôt.
// Usage : npm run verifier-credentials-n8n   (code de sortie 1 si un écart)
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import pg from 'pg';

/** Credentials attendus : nom du workflow → nom du nœud → { type: nom du credential }. */
export function credentialsAttendus(workflows) {
  return new Map(workflows.map((wf) => [wf.name, new Map(wf.nodes.filter((n) => n.credentials)
    .map((n) => [n.name, Object.fromEntries(Object.entries(n.credentials).map(([type, c]) => [type, c.name]))]))]));
}

/**
 * Écarts entre l'attendu et ce que n8n utilise.
 * @param {Map} attendus résultat de credentialsAttendus()
 * @param {{workflow: string, version: string, noeud: string, type: string, credential_id: string|null}[]} deployes
 * @param {Map<string, string>} nomsParId identifiant du credential n8n → son nom
 */
export function ecartsCredentials(attendus, deployes, nomsParId) {
  const ecarts = [];
  for (const d of deployes) {
    const parNoeud = attendus.get(d.workflow);
    if (!parNoeud) continue;   // workflow absent du dépôt (essai) : non contrôlé
    const attendu = parNoeud.get(d.noeud)?.[d.type] ?? null;
    const obtenu = d.credential_id ? (nomsParId.get(d.credential_id) ?? `inconnu (${d.credential_id})`) : null;
    if (attendu !== obtenu) ecarts.push({ ...d, attendu, obtenu });
  }
  // Nœud à credential prévu, mais sans credential dans n8n.
  const vus = new Set(deployes.map((d) => `${d.workflow}|${d.version}|${d.noeud}|${d.type}`));
  const versions = new Map();
  for (const d of deployes) versions.set(d.workflow, new Set([...(versions.get(d.workflow) ?? []), d.version]));
  for (const [workflow, parNoeud] of attendus) {
    for (const version of versions.get(workflow) ?? []) {
      for (const [noeud, types] of parNoeud) {
        for (const [type, attendu] of Object.entries(types)) {
          if (!vus.has(`${workflow}|${version}|${noeud}|${type}`)) ecarts.push({ workflow, version, noeud, type, attendu, obtenu: null });
        }
      }
    }
  }
  return ecarts;
}

export const WORKFLOW_ERREURS = 'Mizan – Erreurs';
// Réglages d'exécution du fichier du dépôt à retrouver dans n8n.
const REGLAGES_CONTROLES = ['saveDataSuccessExecution', 'saveDataErrorExecution', 'executionTimeout'];
// Valeur appliquée par n8n quand le réglage est absent ou laissé sur « Default ».
const DEFAUTS_N8N = Object.freeze({ saveDataSuccessExecution: 'all', saveDataErrorExecution: 'all', executionTimeout: -1 });
const valeurEffective = (cle, v) => (v === undefined || v === null || v === 'DEFAULT' ? DEFAUTS_N8N[cle] : v);

/**
 * Écarts de réglages entre le dépôt et n8n (D-086).
 * @param {object[]} workflows fichiers du dépôt
 * @param {{id: string, name: string, active: boolean, settings: object|null}[]} deployes workflows non archivés de n8n
 */
export function ecartsReglages(workflows, deployes) {
  const ecarts = [];
  const depot = new Map(workflows.map((w) => [w.name, w]));
  const erreurs = deployes.filter((d) => d.name === WORKFLOW_ERREURS);
  if (erreurs.length !== 1) ecarts.push({ workflow: WORKFLOW_ERREURS, reglage: 'présence', attendu: 'un seul workflow', obtenu: String(erreurs.length) });
  // n8n 2.41.7 n'exécute que la version publiée d'un workflow d'erreur (et ne le
  // propose comme « Error workflow » que s'il est publié).
  if (erreurs.length === 1 && !erreurs[0].active) ecarts.push({ workflow: WORKFLOW_ERREURS, reglage: 'publication', attendu: 'publié', obtenu: 'non publié' });
  const idErreurs = erreurs[0]?.id ?? null;
  for (const d of deployes) {
    const fichier = depot.get(d.name);
    if (!fichier) continue;   // workflow absent du dépôt (essai) : non contrôlé
    const reglages = d.settings ?? {};
    if (d.name === WORKFLOW_ERREURS) {
      if (reglages.errorWorkflow) ecarts.push({ workflow: d.name, reglage: 'errorWorkflow', attendu: 'aucun', obtenu: reglages.errorWorkflow });
    } else if (d.active && reglages.errorWorkflow !== idErreurs) {
      ecarts.push({ workflow: d.name, reglage: 'errorWorkflow', attendu: `${WORKFLOW_ERREURS} (${idErreurs})`, obtenu: reglages.errorWorkflow ?? 'aucun' });
    }
    if (!d.active) continue;
    for (const cle of REGLAGES_CONTROLES) {
      const attendu = fichier.settings?.[cle];
      const obtenu = valeurEffective(cle, reglages[cle]);
      if (attendu !== undefined && obtenu !== attendu) ecarts.push({ workflow: d.name, reglage: cle, attendu, obtenu });
    }
  }
  return ecarts;
}

async function principal() {
  if (existsSync('.env')) process.loadEnvFile('.env');
  const workflows = readdirSync('workflows').filter((f) => f.endsWith('.json'))
    .map((f) => JSON.parse(readFileSync(`workflows/${f}`, 'utf8')));
  const client = new pg.Client({
    host: 'localhost', port: 5432, user: process.env.POSTGRES_USER, password: process.env.POSTGRES_PASSWORD, database: process.env.POSTGRES_DB,
  });
  await client.connect();
  try {
    await client.query('SET default_transaction_read_only = on');
    const { rows: deployes } = await client.query(`
      SELECT w.name AS workflow, v.version, n ->> 'name' AS noeud, c.key AS type, c.value ->> 'id' AS credential_id
      FROM workflow_entity w
      CROSS JOIN LATERAL (
          SELECT 'brouillon' AS version, w.nodes AS nodes
          UNION ALL
          SELECT 'publiée', h.nodes FROM workflow_history h WHERE h."versionId" = w."activeVersionId" AND w.active) v
      CROSS JOIN LATERAL json_array_elements(v.nodes) n
      CROSS JOIN LATERAL json_each(coalesce(n -> 'credentials', '{}'::json)) c
      WHERE NOT w."isArchived"`);
    // Pour une version sans aucun nœud à credential, il faut quand même la connaître.
    const { rows: versions } = await client.query(`
      SELECT w.name AS workflow, 'brouillon' AS version FROM workflow_entity w WHERE NOT w."isArchived"
      UNION ALL SELECT w.name, 'publiée' FROM workflow_entity w WHERE NOT w."isArchived" AND w.active AND w."activeVersionId" IS NOT NULL`);
    const { rows: credentials } = await client.query('SELECT id, name FROM credentials_entity');
    const { rows: reglagesN8n } = await client.query('SELECT id, name, active, settings FROM workflow_entity WHERE NOT "isArchived"');
    const ecartsR = ecartsReglages(workflows, reglagesN8n);
    const attendus = credentialsAttendus(workflows);
    const lignes = [...deployes, ...versions.map((v) => ({ ...v, noeud: null, type: null, credential_id: null }))]
      .filter((d) => d.noeud !== null);
    const ecarts = ecartsCredentials(attendus, lignes, new Map(credentials.map((c) => [c.id, c.name])));
    const controles = new Set(versions.filter((v) => attendus.has(v.workflow)).map((v) => `${v.workflow} (${v.version})`));
    if (!ecarts.length && !ecartsR.length) {
      console.log(`Credentials et réglages conformes au dépôt : ${controles.size} version(s) de workflow contrôlée(s).`);
      return;
    }
    console.log(`${ecarts.length + ecartsR.length} écart(s) :`);
    for (const e of ecarts) {
      console.log(`- ${e.workflow} (${e.version}) — nœud « ${e.noeud} » : ${e.obtenu ?? 'aucun credential'} au lieu de ${e.attendu ?? 'aucun'}`);
    }
    for (const e of ecartsR) {
      console.log(`- ${e.workflow} — réglage « ${e.reglage} » : ${e.obtenu} au lieu de ${e.attendu}`);
    }
    process.exitCode = 1;
  } finally {
    await client.end();
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  principal().catch((e) => { console.error(e.message); process.exitCode = 1; });
}
