// Décision du second responsable FICTIF sur une demande du référentiel
// (D-062, D1) : les quatre yeux exigent deux personnes, et Mohamed est le
// seul utilisateur réel. La décision passe par les mêmes déclencheurs que
// toute décision (rôle, quatre yeux, méthode, justification) et porte
// canal = 'simulation' au journal, pour la distinguer d'une décision réelle.
// Usage :
//   npm run simuler-second-responsable                       liste les demandes en attente
//   npm run simuler-second-responsable -- --demande 3 --approuver rib_rappel_contact_connu --justification "…"
//   npm run simuler-second-responsable -- --demande 3 --refuser --justification "…"
//   npm run simuler-second-responsable -- --annulation 2 --approuver --justification "…"   (annulation d'un rapprochement, D-077)
//   npm run simuler-second-responsable -- --annulation 2 --refuser --justification "…"
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

/** Demandes d'annulation de rapprochement en attente (D-077), avec toutes les factures concernées. */
export async function annulationsEnAttente(client) {
  const { rows } = await client.query(`
    SELECT d.id, u.nom AS demande_par, d.justification, l.date_operation::text AS date_operation, l.libelle, l.debit,
           (SELECT string_agg(f.numero || ' (' || r.role || ')', ', ' ORDER BY r.role DESC, f.id)
            FROM rapprochements r JOIN factures f ON f.id = r.facture_id WHERE r.proposition_id = d.proposition_id) AS factures
    FROM demandes_annulation d JOIN utilisateurs u ON u.id = d.demande_par
    JOIN propositions_rapprochement p ON p.id = d.proposition_id JOIN lignes_releve l ON l.id = p.ligne_releve_id
    WHERE NOT EXISTS (SELECT 1 FROM decisions_annulation x WHERE x.demande_id = d.id) ORDER BY d.id`);
  return rows;
}

/** Décision du compte fictif sur une demande d'annulation (mêmes déclencheurs : rôle, quatre yeux, justification). */
export async function deciderAnnulationCommeSecondResponsable(client, { demandeId, decision, justification }) {
  const { rows: [u] } = await client.query('SELECT id FROM utilisateurs WHERE nom = $1 AND fictif', [UTILISATEURS_DEMO[0].nom]);
  if (!u) throw new Error('compte fictif absent : lancer d\'abord npm run charger-utilisateurs-demo');
  const { rows: [d] } = await client.query(
    `INSERT INTO decisions_annulation (demande_id, decision, utilisateur_id, justification, canal)
     VALUES ($1, $2, $3, $4, 'simulation') RETURNING id`,
    [demandeId, decision, u.id, justification],
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
    const annulationId = arg('--annulation');
    if (annulationId) {
      const decision = process.argv.includes('--approuver') ? 'approuvee' : (process.argv.includes('--refuser') ? 'refusee' : null);
      if (!decision) throw new Error('--approuver ou --refuser');
      const id = await deciderAnnulationCommeSecondResponsable(client, { demandeId: Number(annulationId), decision, justification: arg('--justification') });
      console.log(`Décision d'annulation n° ${id} enregistrée (${decision}, canal « simulation »).`);
      return;
    }
    const demandeId = arg('--demande');
    if (!demandeId) {
      const demandes = await demandesEnAttente(client);
      const annulations = await annulationsEnAttente(client);
      if (!demandes.length && !annulations.length) console.log('Aucune demande en attente.');
      for (const d of demandes) {
        console.log(`n° ${d.id} — ${d.type_demande} — facture ${d.facture ?? '—'} — par ${d.demande_par} — ${JSON.stringify(d.donnees)} — « ${d.justification} »`);
      }
      for (const a of annulations) {
        console.log(`annulation n° ${a.id} — ${a.date_operation} ${a.libelle} (${a.debit} TND) — factures : ${a.factures} — par ${a.demande_par} — « ${a.justification} »`);
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
