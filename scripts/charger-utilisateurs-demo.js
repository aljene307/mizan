// Crée l'utilisateur de démonstration, clairement fictif (D-056) : les quatre
// yeux exigent deux personnes distinctes ; Mohamed aura son propre compte à
// l'étape 5 (validation par Telegram), celui-ci tient le second rôle.
// Idempotent ; chaque création est tracée au journal d'audit. Rôle utilisé :
// l'administrateur (mizan_app ne peut pas créer d'utilisateur).
// Usage : npm run charger-utilisateurs-demo [-- --base mizan_test]
import { existsSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import pg from 'pg';

const ACTEUR = 'script:charger-utilisateurs-demo';

export const UTILISATEURS_DEMO = Object.freeze([
  { nom: 'Démo – Responsable fictif (second contrôleur)', role: 'responsable' },
]);

/**
 * @param {pg.Client} client connexion ouverte (administrateur)
 * @returns {Promise<number>} nombre d'utilisateurs créés
 */
export async function chargerUtilisateursDemo(client) {
  let crees = 0;
  await client.query('BEGIN');
  try {
    for (const u of UTILISATEURS_DEMO) {
      const { rows } = await client.query(
        `INSERT INTO utilisateurs (nom, role, fictif)
         SELECT $1::text, $2::text, TRUE WHERE NOT EXISTS (SELECT 1 FROM utilisateurs WHERE nom = $1::text)
         RETURNING id`,
        [u.nom, u.role],
      );
      if (rows.length) {
        crees += 1;
        await client.query(
          `INSERT INTO journal_audit (acteur, action, entite, entite_id, donnees_apres)
           VALUES ($1, 'utilisateur.cree', 'utilisateurs', $2, $3)`,
          [ACTEUR, String(rows[0].id), { nom: u.nom, role: u.role, fictif: true }],
        );
      }
    }
    await client.query('COMMIT');
  } catch (erreur) {
    await client.query('ROLLBACK');
    throw erreur;
  }
  return crees;
}

async function principal() {
  if (existsSync('.env')) process.loadEnvFile('.env');
  const indexBase = process.argv.indexOf('--base');
  const base = indexBase > -1 ? process.argv[indexBase + 1] : (process.env.MIZAN_DB ?? 'mizan');
  const client = new pg.Client({
    host: 'localhost', port: 5432, user: process.env.POSTGRES_USER, password: process.env.POSTGRES_PASSWORD, database: base,
  });
  await client.connect();
  try {
    const crees = await chargerUtilisateursDemo(client);
    console.log(`Base ${base} : ${crees} utilisateur(s) de démonstration créé(s) sur ${UTILISATEURS_DEMO.length}.`);
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
