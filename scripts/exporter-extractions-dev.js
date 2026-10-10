// Export des extractions du lot de DÉVELOPPEMENT (D-078), à la version figée
// de la chaîne (D-053, D-059), pour la reconstruction sans appel au LLM.
// Pour chaque document de lots.json « dev » : empreinte du fichier, et la
// dernière extraction valide de cette version, avec tout ce que
// enregistrer_extraction() a reçu. Un fichier identique à un autre (même
// empreinte) n'est exporté qu'une fois : au rejeu, il est réutilisé comme
// le fait le workflow. Le lot de test n'est jamais lu (lecture protégée).
// Usage : npm run exporter-extractions-dev   → demo/extractions-dev.json
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { basename } from 'node:path';
import pg from 'pg';
import { documentsDev, lireFichier } from './lecture-protegee.js';

export const VERSION_CHAINE = 'D-053';
export const CHAMPS_EXTRACTION = Object.freeze([
  'resultat', 'code_resultat', 'methode_lecture', 'fournisseur_llm', 'modele', 'version_prompt', 'empreinte_prompt',
  'parametres_generation', 'duree_lecture_ms', 'duree_llm_ms', 'jetons_entree', 'jetons_sortie', 'jetons_reflexion',
  'tentatives', 'donnees', 'erreurs', 'verifications_source', 'alertes_source', 'texte_source', 'donnees_brutes',
  'corrections_code', 'signalements_code', 'propositions', 'version_chaine',
]);
const sha256 = (octets) => createHash('sha256').update(octets).digest('hex');

async function principal() {
  if (existsSync('.env')) process.loadEnvFile('.env');
  const documents = documentsDev().map((d) => ({ ...d, fichier_sha256: sha256(lireFichier(d.fichier)) }));
  const client = new pg.Client({
    host: 'localhost', port: 5432, user: process.env.POSTGRES_USER, password: process.env.POSTGRES_PASSWORD,
    database: process.env.MIZAN_DB ?? 'mizan',
  });
  await client.connect();
  try {
    await client.query('SET default_transaction_read_only = on');
    const { rows } = await client.query(`
      SELECT DISTINCT ON (e.fichier_sha256) e.fichier_sha256, ${CHAMPS_EXTRACTION.map((c) => `e.${c}`).join(', ')}
      FROM extractions e
      WHERE e.version_chaine = $1 AND e.resultat = 'valide' AND e.fichier_sha256 = ANY ($2)
      ORDER BY e.fichier_sha256, e.id DESC`, [VERSION_CHAINE, documents.map((d) => d.fichier_sha256)]);
    const parEmpreinte = new Map(rows.map((r) => [r.fichier_sha256, r]));
    const vus = new Map();
    const sortie = documents.map((d) => {
      const base = { id: d.id, fichier: basename(d.fichier), format: d.format, fichier_sha256: d.fichier_sha256 };
      if (vus.has(d.fichier_sha256)) return { ...base, meme_fichier_que: vus.get(d.fichier_sha256) };
      const e = parEmpreinte.get(d.fichier_sha256);
      if (!e) throw new Error(`${d.id} : aucune extraction valide à la version ${VERSION_CHAINE} en base`);
      vus.set(d.fichier_sha256, d.id);
      return { ...base, extraction: Object.fromEntries(CHAMPS_EXTRACTION.map((c) => [c, e[c]])) };
    });
    mkdirSync('demo', { recursive: true });
    writeFileSync('demo/extractions-dev.json', `${JSON.stringify({
      description: 'Extractions du lot de développement à la version figée de la chaîne, rejouées par la reconstruction (D-078) sans appel au LLM. Données synthétiques.',
      version_chaine: VERSION_CHAINE, documents: sortie,
    }, null, 2)}\n`);
    const reutilises = sortie.filter((d) => d.meme_fichier_que).length;
    console.log(`demo/extractions-dev.json : ${sortie.length} documents du lot de développement, `
      + `${sortie.length - reutilises} extractions, ${reutilises} fichier(s) identique(s) à un autre (réutilisation).`);
  } finally {
    await client.end();
  }
}

if (process.argv[1]?.endsWith('exporter-extractions-dev.js')) {
  principal().catch((e) => { console.error(e.message); process.exitCode = 1; });
}
