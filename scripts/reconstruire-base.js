// Reconstruction d'une base propre et reproductible (D-078), sans appel au
// LLM ni compte Telegram : les extractions enregistrées du lot de
// développement sont rejouées par les MÊMES fonctions de la base que les
// workflows (réception, extraction, contrôles, relevé, rapprochement).
// Usage :
//   npm run reconstruire-base -- --etat demonstration   factures, relevé, scénario, décisions en attente
//   npm run reconstruire-base -- --etat evaluation      schéma, référentiel, utilisateurs ; aucune facture
// Options : --base <nom> (défaut : MIZAN_DB) ; --confirmer <nom> (tests seulement :
// remplace la saisie, doit nommer exactement la base visée).
// Protections : refus si un workflow Mizan est publié dans n8n, sauf « Mizan –
// Erreurs » (D-086) (base de
// travail) ; plan affiché ; confirmation par le nom de la base ; sauvegarde
// relue avant d'effacer (sans option pour l'éviter, D-078 c1) ; lot de test
// jamais lu (lecture protégée) ; inscriptions Telegram réelles conservées.
import { createHash } from 'node:crypto';
import { existsSync } from 'node:fs';
import { createInterface } from 'node:readline/promises';
import { spawnSync } from 'node:child_process';
import pg from 'pg';
import { documentsDev, lireFichier } from './lecture-protegee.js';
import { sauvegarder } from './sauvegarder-base.js';
import { chargerReferentiel } from './charger-referentiel.js';
import { chargerUtilisateursDemo, UTILISATEURS_DEMO } from './charger-utilisateurs-demo.js';
import { payloadReutilisation } from '../src/extractionWorkflow.js';
import { controlerFacture } from '../src/controles/regles.js';
import { enMillimes, diviserArrondi, montantTva } from '../src/montants.js';
import { formeCourteMatricule, normaliserMatricule } from '../src/matricule.js';
import { ribValide } from '../src/rib.js';
import { normaliserTexte } from '../src/comparaison.js';
import { lireReleveCsv } from '../src/rapprochement/releve.js';
import { rapprocher } from '../src/rapprochement/appariement.js';

const arg = (nom) => { const i = process.argv.indexOf(nom); return i > -1 ? process.argv[i + 1] : undefined; };
const NOM_BASE = /^[a-z_][a-z0-9_]{0,62}$/;
const EXECUTION = 'reconstruction';
// Compte de l'entreprise (fictif), identique à celui du workflow du relevé (vérifié par un test).
export const COMPTE_ENTREPRISE = Object.freeze({ banque: 'Banque Démo 99', rib_compte: '99330228027133819365', devise: 'TND' });
export const RELEVE_DEV = 'data/synthetic/releve/releve-2026-01-01_2026-09-30.csv';
const DEPS_CONTROLES = { enMillimes, diviserArrondi, montantTva, formeCourteMatricule, normaliserMatricule, ribValide, normaliserTexte };

const client = (base, utilisateur = 'admin') => new pg.Client({
  host: 'localhost', port: 5432, database: base,
  ...(utilisateur === 'app'
    ? { user: 'mizan_app', password: process.env.MIZAN_APP_PASSWORD }
    : { user: process.env.POSTGRES_USER, password: process.env.POSTGRES_PASSWORD }),
});
async function avec(base, utilisateur, travail) {
  const c = client(base, utilisateur);
  await c.connect();
  try { return await travail(c); } finally { await c.end(); }
}

// --- Vérifications préalables ---------------------------------------------------------------

// « Mizan – Erreurs » (D-086) reste publié : n8n n'exécute que la version publiée
// d'un workflow d'erreur. Il n'écrit que si un AUTRE workflow publié échoue ; or
// ceux-là doivent être dépubliés : il ne peut donc rien écrire pendant l'opération.
export const PUBLIE_AUTORISE = 'Mizan – Erreurs';
/** Workflows publiés qui empêchent une reconstruction ou une évaluation. */
export const publiesBloquants = (noms) => noms.filter((n) => n !== PUBLIE_AUTORISE);

/** Workflows Mizan publiés dans n8n (base interne de n8n, lecture seule), sauf « Mizan – Erreurs ». */
export async function workflowsPublies() {
  return avec(process.env.POSTGRES_DB, 'admin', async (c) => {
    try {
      const { rows } = await c.query(`SELECT name FROM workflow_entity
        WHERE active AND NOT "isArchived" AND name LIKE 'Mizan%' ORDER BY name`);
      return publiesBloquants(rows.map((r) => r.name));
    } catch (e) {
      if (e.code === '42P01') return [];   // n8n jamais démarré : aucune table, aucun workflow
      throw e;
    }
  });
}

async function baseExiste(base) {
  return avec(process.env.POSTGRES_DB, 'admin', async (c) => (await c.query('SELECT 1 FROM pg_database WHERE datname = $1', [base])).rowCount === 1);
}

/**
 * Ce qui est conservé : utilisateurs réels, leurs adresses actives, le curseur de lecture du canal.
 * Base créée mais sans schéma (première installation : db/init crée la base, les migrations
 * ne sont pas encore appliquées) : rien à conserver (défaut trouvé sur un clone propre, 2026-10-10).
 */
export async function lireAConserver(base) {
  return avec(base, 'admin', async (c) => {
    try {
      const { rows: utilisateurs } = await c.query(`SELECT u.nom, u.role, u.actif,
          coalesce(jsonb_agg(jsonb_build_object('canal', a.canal, 'adresse', a.adresse)) FILTER (WHERE a.id IS NOT NULL), '[]') AS adresses
        FROM utilisateurs u LEFT JOIN adresses_canal a ON a.utilisateur_id = u.id AND a.active
        WHERE NOT u.fictif GROUP BY u.id ORDER BY u.id`);
      const { rows: curseurs } = await c.query('SELECT canal, curseur FROM etats_canal');
      return { utilisateurs, curseurs };
    } catch (e) {
      if (e.code === '42P01') return { utilisateurs: [], curseurs: [] };   // base sans schéma
      throw e;
    }
  });
}

// --- Reconstruction --------------------------------------------------------------------------

function dbmate(base, ...commande) {
  const url = `postgres://${process.env.POSTGRES_USER}:${process.env.POSTGRES_PASSWORD}@postgres:5432/${base}?sslmode=disable`;
  const r = spawnSync('docker', ['compose', 'run', '--rm', '-e', `DATABASE_URL=${url}`, 'dbmate', '--no-dump-schema', ...commande], { encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`dbmate ${commande.join(' ')} : ${r.stderr || r.stdout}`);
}

async function recreer(base) {
  // FORCE : les connexions ouvertes (pool de Grafana, credentials n8n) sont fermées.
  await avec(process.env.POSTGRES_DB, 'admin', (c) => c.query(`DROP DATABASE IF EXISTS "${base}" WITH (FORCE)`));
  dbmate(base, 'create');
  dbmate(base, 'up');
}

async function chargerSocle(base, conserve) {
  await avec(base, 'admin', async (c) => {
    await chargerReferentiel(c, JSON.parse(lireFichier('data/synthetic/referentiel/fournisseurs.json', 'utf8')));
    await chargerUtilisateursDemo(c);
    for (const u of conserve.utilisateurs) {
      const { rows: [n] } = await c.query('INSERT INTO utilisateurs (nom, role, actif, fictif) VALUES ($1, $2, $3, FALSE) RETURNING id',
        [u.nom, u.role, u.actif]);
      for (const a of u.adresses) await c.query('INSERT INTO adresses_canal (utilisateur_id, canal, adresse) VALUES ($1, $2, $3)', [n.id, a.canal, a.adresse]);
      await c.query(`INSERT INTO journal_audit (acteur, action, entite, entite_id, donnees_apres)
        VALUES ('script:reconstruire-base', 'utilisateur.conserve', 'utilisateurs', $1, $2)`,
      [String(n.id), { nom: u.nom, role: u.role, adresses: u.adresses.length }]);
    }
    for (const k of conserve.curseurs) {
      await c.query(`INSERT INTO etats_canal (canal, curseur) VALUES ($1, $2)
        ON CONFLICT (canal) DO UPDATE SET curseur = excluded.curseur`, [k.canal, k.curseur]);
    }
  });
}

/** Réception et extraction rejouées, dans l'ordre des noms de fichier (protocole D-082). */
async function rejouerFactures(base) {
  const exportDev = JSON.parse(lireFichier('demo/extractions-dev.json', 'utf8'));
  const parFichier = new Map(exportDev.documents.map((d) => [d.fichier, d]));
  const documents = documentsDev().sort((a, b) => a.fichier.localeCompare(b.fichier));
  return avec(base, 'app', async (c) => {
    for (const d of documents) {
      const nom = d.fichier.split('/').pop();
      const e = parFichier.get(nom);
      if (!e) throw new Error(`${d.id} : absent de demo/extractions-dev.json`);
      const empreinte = createHash('sha256').update(lireFichier(d.fichier)).digest('hex');
      if (empreinte !== e.fichier_sha256) throw new Error(`${d.id} : le fichier ne correspond plus à l'extraction exportée`);
      await c.query('SELECT * FROM enregistrer_reception($1, $2, $3, $4, $5, $6)', ['dossier', null, d.format, nom, empreinte, EXECUTION]);
    }
    let extraites = 0;
    for (;;) {
      const { rows: [r] } = await c.query('SELECT * FROM reserver_facture_a_extraire()');
      if (!r) break;
      const nom = (await c.query('SELECT fichier_nom FROM factures WHERE id = $1', [r.facture_id])).rows[0].fichier_nom;
      const e = parFichier.get(nom);
      const { rows: [existante] } = await c.query('SELECT * FROM extraction_valide_existante($1, $2)', [e.fichier_sha256, exportDev.version_chaine]);
      const payload = existante?.extraction_id
        ? payloadReutilisation(r, existante, EXECUTION).payload
        : { facture_id: r.facture_id, ...e.extraction, execution_n8n_id: EXECUTION };
      await c.query('SELECT enregistrer_extraction($1::jsonb)', [payload]);
      extraites += 1;
    }
    return extraites;
  });
}

/** Un seul passage des contrôles, après toutes les extractions (protocole D-082). */
async function rejouerControles(base) {
  return avec(base, 'app', async (c) => {
    let n = 0;
    for (;;) {
      const { rows: [r] } = await c.query('SELECT * FROM reserver_facture_a_controler()');
      if (!r) break;
      const { rows: [{ contexte }] } = await c.query('SELECT contexte_controles($1::bigint) AS contexte', [r.facture_id]);
      const resultat = controlerFacture(contexte, DEPS_CONTROLES);
      await c.query('SELECT enregistrer_controles($1::jsonb)', [{
        facture_id: r.facture_id, fournisseur_id: resultat.fournisseur_id, execution_n8n_id: EXECUTION, resultats: resultat.resultats,
      }]);
      n += 1;
    }
    return n;
  });
}

/** Décisions du scénario, par le compte fictif, canal « simulation ». */
async function rejouerScenario(base, scenario) {
  await avec(base, 'admin', async (c) => {
    const { rows: [u] } = await c.query('SELECT id FROM utilisateurs WHERE nom = $1 AND fictif', [UTILISATEURS_DEMO[0].nom]);
    for (const d of scenario.decisions_factures) {
      const { rows: [f] } = await c.query("SELECT id FROM factures WHERE fichier_nom LIKE $1 || '.%'", [d.document]);
      if (!f) throw new Error(`scénario : facture ${d.document} absente`);
      await c.query(`INSERT INTO decisions_humaines (facture_id, utilisateur_id, decision, justification, canal)
        VALUES ($1, $2, $3, $4, 'simulation')`, [f.id, u.id, d.decision, d.justification]);
    }
  });
}

/** Relevé de développement importé et rapproché, comme le workflow du relevé. */
async function rejouerReleve(base) {
  const texte = lireFichier(RELEVE_DEV, 'utf8');
  const r = lireReleveCsv(texte);
  return avec(base, 'app', async (c) => {
    const { rows: [rel] } = await c.query(
      "SELECT * FROM enregistrer_releve($1::jsonb || jsonb_build_object('fichier_sha256', encode(sha256(convert_to($2, 'UTF8')), 'hex')))",
      [{ ...COMPTE_ENTREPRISE, date_debut: r.date_debut, date_fin: r.date_fin, solde_initial: r.solde_initial, solde_final: r.solde_final,
        fichier_nom: RELEVE_DEV.split('/').pop(), execution_n8n_id: EXECUTION, lignes: r.lignes }, texte]);
    const { rows: [{ contexte }] } = await c.query('SELECT contexte_rapprochement($1::bigint) AS contexte', [rel.releve_id]);
    const a = rapprocher(contexte, { enMillimes });
    const { rows: [{ bilan }] } = await c.query('SELECT enregistrer_rapprochements($1::jsonb) AS bilan',
      [{ releve_id: rel.releve_id, execution_n8n_id: EXECUTION, ...a }]);
    return { operations: r.lignes.length, ...bilan };
  });
}

async function resume(base) {
  return avec(base, 'admin', async (c) => (await c.query(`SELECT
      (SELECT count(*) FROM factures)::int AS factures,
      (SELECT jsonb_object_agg(statut, n) FROM (SELECT statut, count(*)::int AS n FROM factures GROUP BY statut) s) AS statuts,
      (SELECT count(*) FROM extractions)::int AS extractions,
      (SELECT count(*) FROM propositions_rapprochement WHERE statut = 'propose')::int AS propositions_en_attente,
      (SELECT count(*) FROM signalements_paiement WHERE statut = 'ouvert')::int AS signalements_ouverts,
      (SELECT count(*) FROM utilisateurs WHERE NOT fictif)::int AS utilisateurs_conserves,
      (SELECT count(*) FROM adresses_canal WHERE active)::int AS adresses_actives`)).rows[0]);
}

// --- Programme principal ------------------------------------------------------------------------

export async function reconstruire({ base, etat, confirmer, saisir }) {
  if (!['demonstration', 'evaluation'].includes(etat)) throw new Error('--etat demonstration ou --etat evaluation');
  if (!NOM_BASE.test(base) || [process.env.POSTGRES_DB, 'postgres', 'template0', 'template1'].includes(base)) {
    throw new Error(`base refusée : « ${base} »`);
  }
  const travail = process.env.MIZAN_DB ?? 'mizan';
  if (base === travail) {
    const publies = await workflowsPublies();
    if (publies.length) {
      throw new Error(`refus : des workflows Mizan sont publiés dans n8n et écrivent dans « ${base} ». Dépubliez-les d'abord :\n`
        + publies.map((n) => `  - ${n}`).join('\n'));
    }
  }
  const existe = await baseExiste(base);
  const conserve = existe ? await lireAConserver(base) : { utilisateurs: [], curseurs: [] };
  console.log([
    `Reconstruction de la base « ${base} », état « ${etat} ».`,
    existe ? `  1. Sauvegarde de la base actuelle dans sauvegardes/, relue avant d'effacer.` : '  1. La base n\'existe pas : rien à sauvegarder.',
    `  2. Base « ${base} » EFFACÉE puis recréée (toutes les migrations).`,
    '  3. Référentiel fictif et compte fictif chargés.',
    `  4. Conservés : ${conserve.utilisateurs.length} utilisateur(s) réel(s) (${conserve.utilisateurs.map((u) => u.nom).join(', ') || 'aucun'}), `
      + `${conserve.utilisateurs.reduce((n, u) => n + u.adresses.length, 0)} adresse(s) Telegram, curseur de lecture du canal.`,
    ...(etat === 'demonstration' ? [
      '  5. 42 factures du lot de développement rejouées (extractions enregistrées, aucun appel au LLM), un passage des contrôles.',
      '  6. Décisions du scénario (demo/scenario.json), relevé de développement importé et rapproché, lot d\'ordres proposé.',
    ] : ['  5. Aucune facture, aucun relevé (base vierge pour l\'évaluation, D-082).']),
    '  Le lot de test n\'est jamais lu. Aucune base n8n n\'est touchée.',
  ].join('\n'));
  const reponse = confirmer ?? await saisir(`Pour confirmer, tapez le nom de la base (${base}) : `);
  if (reponse !== base) throw new Error('confirmation absente ou différente du nom de la base : rien n\'a été fait');

  const sauvegarde = existe ? sauvegarder(base) : null;
  if (sauvegarde) console.log(`Sauvegarde : ${sauvegarde.chemin} (${sauvegarde.objets} objets, relue).`);
  await recreer(base);
  await chargerSocle(base, conserve);
  const bilan = { etat, sauvegarde: sauvegarde?.chemin ?? null };
  if (etat === 'demonstration') {
    const scenario = JSON.parse(lireFichier('demo/scenario.json', 'utf8'));
    bilan.extractions = await rejouerFactures(base);
    bilan.controles = await rejouerControles(base);
    await rejouerScenario(base, scenario);
    bilan.releve = await rejouerReleve(base);
    if (scenario.proposer_lot_ordres) {
      bilan.lot = await avec(base, 'app', async (c) => (await c.query("SELECT proposer_lot_paiement('{\"execution_n8n_id\": \"reconstruction\"}') AS b")).rows[0].b);
    }
  }
  bilan.resume = await resume(base);
  return bilan;
}

async function principal() {
  if (existsSync('.env')) process.loadEnvFile('.env');
  const lecteur = createInterface({ input: process.stdin, output: process.stdout });
  try {
    const bilan = await reconstruire({
      base: arg('--base') ?? process.env.MIZAN_DB ?? 'mizan', etat: arg('--etat'), confirmer: arg('--confirmer'),
      saisir: async (question) => (await lecteur.question(question)).trim(),
    });
    console.log(JSON.stringify(bilan, null, 2));
    console.log('Terminé. Republiez les workflows dans n8n si besoin.');
  } finally {
    lecteur.close();
  }
}

if (process.argv[1]?.endsWith('reconstruire-base.js')) {
  principal().catch((e) => { console.error(e.message); process.exitCode = 1; });
}
