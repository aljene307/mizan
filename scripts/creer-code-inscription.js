// Crée (si besoin) un utilisateur et un code d'inscription à usage unique
// pour le lier à un canal (D-062, B1). Le code est affiché UNE fois ; la base
// n'en garde que l'empreinte. Validité : parametres_controle
// « inscription.validite_minutes ». Rôle utilisé : l'administrateur (seul
// autorisé à créer un utilisateur ou un code).
// Usage : npm run creer-code-inscription -- --nom "Mohamed Aljene" --role responsable [--canal telegram]
import { randomBytes } from 'node:crypto';
import { existsSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import pg from 'pg';

const ACTEUR = 'script:creer-code-inscription';
const arg = (nom, defaut) => { const i = process.argv.indexOf(nom); return i > -1 ? process.argv[i + 1] : defaut; };

/** Code lisible : 4 groupes de 4 caractères sans ambiguïté (ni 0/O ni 1/I). */
export function nouveauCode() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const octets = randomBytes(16);
  const car = [...octets].map((o) => alphabet[o % alphabet.length]).join('');
  return car.match(/.{4}/g).join('-');
}

/**
 * @param {pg.Client} client connexion administrateur
 * @returns {Promise<{utilisateurId: number, cree: boolean, code: string, expireLe: Date}>}
 */
export async function creerCodeInscription(client, { nom, role, canal }) {
  await client.query('BEGIN');
  try {
    let cree = false;
    let { rows: [u] } = await client.query('SELECT id, role FROM utilisateurs WHERE nom = $1', [nom]);
    if (!u) {
      ({ rows: [u] } = await client.query('INSERT INTO utilisateurs (nom, role) VALUES ($1, $2) RETURNING id, role', [nom, role]));
      cree = true;
      await client.query(
        `INSERT INTO journal_audit (acteur, action, entite, entite_id, donnees_apres) VALUES ($1, 'utilisateur.cree', 'utilisateurs', $2, $3)`,
        [ACTEUR, String(u.id), { nom, role, fictif: false }],
      );
    } else if (u.role !== role) {
      throw new Error(`l'utilisateur « ${nom} » existe déjà avec le rôle ${u.role}`);
    }
    const code = nouveauCode();
    const { rows: [{ id: codeId }] } = await client.query('SELECT creer_code_inscription($1, $2, $3) AS id', [u.id, canal, code]);
    // Instruction séparée : une instruction SQL ne voit pas les lignes qu'elle
    // insère elle-même (la date relue dans la même requête valait NULL).
    const { rows: [c] } = await client.query('SELECT id, expire_le FROM codes_inscription WHERE id = $1', [codeId]);
    if (!(c?.expire_le instanceof Date)) throw new Error('code créé mais date d\'expiration introuvable : rien n\'est enregistré');
    await client.query(
      `INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_apres) VALUES ($1, 'utilisateur.code_inscription_cree', 'utilisateurs', $2, $3, $4)`,
      [ACTEUR, String(u.id), canal, { code_id: c.id, expire_le: c.expire_le }],
    );
    await client.query('COMMIT');
    return { utilisateurId: u.id, cree, code, expireLe: c.expire_le };
  } catch (erreur) {
    await client.query('ROLLBACK');
    throw erreur;
  }
}

async function principal() {
  if (existsSync('.env')) process.loadEnvFile('.env');
  const nom = arg('--nom');
  const role = arg('--role', 'responsable');
  const canal = arg('--canal', 'telegram');
  if (!nom) throw new Error('--nom obligatoire');
  if (!['validateur', 'responsable'].includes(role)) throw new Error('--role validateur ou responsable');
  const client = new pg.Client({
    host: 'localhost', port: 5432, user: process.env.POSTGRES_USER, password: process.env.POSTGRES_PASSWORD,
    database: arg('--base', process.env.MIZAN_DB ?? 'mizan'),
  });
  await client.connect();
  try {
    const r = await creerCodeInscription(client, { nom, role, canal });
    console.log(`${r.cree ? 'Utilisateur créé' : 'Utilisateur existant'} : ${nom} (${role}, n° ${r.utilisateurId}).`);
    console.log(`Code d'inscription (${canal}), à usage unique, valable jusqu'à ${r.expireLe.toISOString()} :\n\n    /start ${r.code}\n`);
  } finally {
    await client.end();
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  principal().catch((erreur) => { console.error(erreur.message); process.exit(1); });
}
