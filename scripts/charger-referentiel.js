// Charge le référentiel fictif (data/synthetic/referentiel/fournisseurs.json)
// dans la base : fournisseurs connus et leur RIB actif. Idempotent : relancer
// le script ne crée aucun doublon. Une seule transaction ; chaque création est
// tracée au journal d'audit. Rôle utilisé : l'administrateur de la base, car
// mizan_app ne peut plus écrire dans le référentiel (D-056) : le chargement
// initial est un acte d'administration ; ensuite, toute création ou tout
// changement de RIB passe par une demande approuvée (quatre yeux).
// Usage : npm run charger-referentiel [-- --base mizan_test]
import { existsSync, readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import pg from 'pg';

const ACTEUR = 'script:charger-referentiel';
const DEBUT_VALIDITE_RIB = '2026-01-01';

/**
 * @param {pg.Client} client connexion ouverte
 * @param {object[]} fournisseurs contenu de referentiel/fournisseurs.json
 * @returns {Promise<{fournisseursCrees: number, ribsCrees: number}>}
 */
export async function chargerReferentiel(client, fournisseurs) {
  let fournisseursCrees = 0;
  let ribsCrees = 0;
  await client.query('BEGIN');
  try {
    for (const f of fournisseurs) {
      const insertion = await client.query(
        `INSERT INTO fournisseurs (raison_sociale, matricule_fiscal, adresse, email)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (matricule_fiscal) DO NOTHING
         RETURNING id`,
        [f.raison_sociale, f.matricule_fiscal, f.adresse, f.email],
      );
      let id;
      if (insertion.rows.length) {
        id = insertion.rows[0].id;
        fournisseursCrees += 1;
        await client.query(
          `INSERT INTO journal_audit (acteur, action, entite, entite_id, donnees_apres)
           VALUES ($1, 'fournisseur.cree', 'fournisseurs', $2, $3)`,
          [ACTEUR, String(id), { code: f.code, raison_sociale: f.raison_sociale, matricule_fiscal: f.matricule_fiscal }],
        );
      } else {
        ({ rows: [{ id }] } = await client.query('SELECT id FROM fournisseurs WHERE matricule_fiscal = $1', [f.matricule_fiscal]));
      }

      const actif = await client.query(
        'SELECT rib FROM fournisseur_ribs WHERE fournisseur_id = $1 AND valide_au IS NULL', [id],
      );
      if (actif.rows.length === 0) {
        await client.query(
          `INSERT INTO fournisseur_ribs (fournisseur_id, rib, banque, valide_du, origine)
           VALUES ($1, $2, $3, $4, 'import')`,
          [id, f.rib, f.banque, DEBUT_VALIDITE_RIB],
        );
        ribsCrees += 1;
        await client.query(
          `INSERT INTO journal_audit (acteur, action, entite, entite_id, donnees_apres)
           VALUES ($1, 'fournisseur.rib_ajoute', 'fournisseurs', $2, $3)`,
          [ACTEUR, String(id), { rib: f.rib, valide_du: DEBUT_VALIDITE_RIB }],
        );
      } else if (actif.rows[0].rib !== f.rib) {
        throw new Error(`${f.code} : le RIB actif en base diffère du référentiel ; changement de RIB à faire à la main`);
      }
    }
    await client.query('COMMIT');
  } catch (erreur) {
    await client.query('ROLLBACK');
    throw erreur;
  }
  return { fournisseursCrees, ribsCrees };
}

async function principal() {
  if (existsSync('.env')) process.loadEnvFile('.env');
  const indexBase = process.argv.indexOf('--base');
  const base = indexBase > -1 ? process.argv[indexBase + 1] : (process.env.MIZAN_DB ?? 'mizan');
  const fournisseurs = JSON.parse(readFileSync('data/synthetic/referentiel/fournisseurs.json', 'utf8'));
  const client = new pg.Client({
    host: 'localhost', port: 5432, user: process.env.POSTGRES_USER, password: process.env.POSTGRES_PASSWORD, database: base,
  });
  await client.connect();
  try {
    const { fournisseursCrees, ribsCrees } = await chargerReferentiel(client, fournisseurs);
    console.log(`Base ${base} : ${fournisseursCrees} fournisseur(s) et ${ribsCrees} RIB créé(s) sur ${fournisseurs.length} fournisseurs du référentiel.`);
  } finally {
    await client.end();
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  principal().catch((erreur) => {
    console.error(erreur.message);
    process.exit(1);
  });
}
