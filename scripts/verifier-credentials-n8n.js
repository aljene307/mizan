// Contrôle des credentials rattachés dans n8n (incident du 2026-10-09 : au
// réimport, n8n a rattaché « PostgreSQL Mizan (lecture) » aux nœuds de
// « Réponses Telegram », qui écrivent). Pour chaque workflow du dépôt présent
// dans n8n, version publiée ET brouillon : chaque nœud doit utiliser le
// credential prévu par le fichier du dépôt (par son nom). Lecture seule de la
// base interne de n8n ; la colonne des secrets chiffrés n'est jamais lue.
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
    const attendus = credentialsAttendus(workflows);
    const lignes = [...deployes, ...versions.map((v) => ({ ...v, noeud: null, type: null, credential_id: null }))]
      .filter((d) => d.noeud !== null);
    const ecarts = ecartsCredentials(attendus, lignes, new Map(credentials.map((c) => [c.id, c.name])));
    const controles = new Set(versions.filter((v) => attendus.has(v.workflow)).map((v) => `${v.workflow} (${v.version})`));
    if (!ecarts.length) {
      console.log(`Credentials conformes au dépôt : ${controles.size} version(s) de workflow contrôlée(s).`);
      return;
    }
    console.log(`${ecarts.length} écart(s) :`);
    for (const e of ecarts) {
      console.log(`- ${e.workflow} (${e.version}) — nœud « ${e.noeud} » : ${e.obtenu ?? 'aucun credential'} au lieu de ${e.attendu ?? 'aucun'}`);
    }
    process.exitCode = 1;
  } finally {
    await client.end();
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  principal().catch((e) => { console.error(e.message); process.exitCode = 1; });
}
