// Décision du second responsable FICTIF sur une demande du référentiel
// (D-062, D1) : les quatre yeux exigent deux personnes, et Mohamed est le
// seul utilisateur réel. La décision passe par les mêmes déclencheurs que
// toute décision (rôle, quatre yeux, méthode, justification) et porte
// canal = 'simulation' au journal, pour la distinguer d'une décision réelle.
// Usage :
//   npm run simuler-second-responsable                       liste les demandes en attente
//   npm run simuler-second-responsable -- --demande 3 --approuver rib_rappel_contact_connu --justification "…"
//   npm run simuler-second-responsable -- --demande 3 --refuser --justification "…"
import { existsSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import pg from 'pg';
import { UTILISATEURS_DEMO } from './charger-utilisateurs-demo.js';

const arg = (nom) => { const i = process.argv.indexOf(nom); return i > -1 ? process.argv[i + 1] : undefined; };

export async function demandesEnAttente(client) {
  const { rows } = await client.query(`
    SELECT d.id, d.type_demande, d.donnees, d.rib_actuel, d.justification, u.nom AS demande_par, f.numero AS facture
    FROM demandes_referentiel d JOIN utilisateurs u ON u.id = d.demande_par LEFT JOIN factures f ON f.id = d.facture_id
    WHERE NOT EXISTS (SELECT 1 FROM decisions_referentiel x WHERE x.demande_id = d.id) ORDER BY d.id`);
  return rows;
}

/** Décision du compte fictif ; renvoie l'identifiant de la décision. */
export async function deciderCommeSecondResponsable(client, { demandeId, decision, methode, justification }) {
  const { rows: [u] } = await client.query('SELECT id FROM utilisateurs WHERE nom = $1 AND fictif', [UTILISATEURS_DEMO[0].nom]);
  if (!u) throw new Error('compte fictif absent : lancer d\'abord npm run charger-utilisateurs-demo');
  const { rows: [d] } = await client.query(
    `INSERT INTO decisions_referentiel (demande_id, decision, utilisateur_id, methode_verification, justification, canal)
     VALUES ($1, $2, $3, $4, $5, 'simulation') RETURNING id`,
    [demandeId, decision, u.id, methode ?? null, justification],
  );
  return d.id;
}

async function principal() {
  if (existsSync('.env')) process.loadEnvFile('.env');
  const client = new pg.Client({
    host: 'localhost', port: 5432, user: process.env.POSTGRES_USER, password: process.env.POSTGRES_PASSWORD,
    database: arg('--base') ?? process.env.MIZAN_DB ?? 'mizan',
  });
  await client.connect();
  try {
    const demandeId = arg('--demande');
    if (!demandeId) {
      const demandes = await demandesEnAttente(client);
      if (!demandes.length) console.log('Aucune demande en attente.');
      for (const d of demandes) {
        console.log(`n° ${d.id} — ${d.type_demande} — facture ${d.facture ?? '—'} — par ${d.demande_par} — ${JSON.stringify(d.donnees)} — « ${d.justification} »`);
      }
      return;
    }
    const approuver = arg('--approuver');
    const decision = approuver ? 'approuvee' : (process.argv.includes('--refuser') ? 'refusee' : null);
    if (!decision) throw new Error('--approuver <méthode> ou --refuser');
    const id = await deciderCommeSecondResponsable(client, { demandeId: Number(demandeId), decision, methode: approuver, justification: arg('--justification') });
    console.log(`Décision n° ${id} enregistrée (${decision}, canal « simulation »).`);
  } finally {
    await client.end();
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  principal().catch((erreur) => { console.error(erreur.message); process.exit(1); });
}
