// Lecture de config_fiscale dans PostgreSQL avec le rôle applicatif mizan_app
// (lecture seule). Les taux ne sont jamais écrits dans le générateur.
import { existsSync } from 'node:fs';
import pg from 'pg';

/**
 * @returns {Promise<object[]>} paramètres fiscaux, triés par clé et date
 */
export async function lireConfigFiscale() {
  if (existsSync('.env')) process.loadEnvFile('.env');
  const client = new pg.Client({
    host: process.env.PGHOST ?? 'localhost',
    port: Number(process.env.PGPORT ?? 5432),
    user: 'mizan_app',
    password: process.env.MIZAN_APP_PASSWORD,
    database: process.env.MIZAN_DB ?? 'mizan',
  });
  await client.connect();
  try {
    const { rows } = await client.query(`
      SELECT cle, valeur::text AS valeur, unite, libelle, conditions,
             valide_du::text AS valide_du, valide_au::text AS valide_au,
             source_libelle, source_url, a_confirmer
      FROM config_fiscale
      ORDER BY cle, valide_du`);
    return rows;
  } finally {
    await client.end();
  }
}
