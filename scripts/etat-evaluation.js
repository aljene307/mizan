// État d'une évaluation en cours (D-082, étapes 8 à 11 du protocole) : factures
// par statut, extractions, ordre de réception, contrôles. Lecture seule.
// Usage : npm run etat-evaluation
import { existsSync } from 'node:fs';
import pg from 'pg';

/** Ordre de réception conforme : identifiants croissants dans l'ordre des noms de fichier (D-082). */
export function ordreConforme(factures) {
  const parId = [...factures].sort((a, b) => Number(a.id) - Number(b.id)).map((f) => f.fichier_nom);
  const parNom = [...parId].sort((a, b) => a.localeCompare(b));
  const ecart = parId.findIndex((n, i) => n !== parNom[i]);
  return ecart === -1 ? null : `position ${ecart + 1} : ${parId[ecart]} reçu à la place de ${parNom[ecart]}`;
}

async function principal() {
  if (existsSync('.env')) process.loadEnvFile('.env');
  const c = new pg.Client({ host: 'localhost', port: 5432, user: process.env.POSTGRES_USER, password: process.env.POSTGRES_PASSWORD,
    database: process.env.MIZAN_DB ?? 'mizan' });
  await c.connect();
  try {
    await c.query('SET default_transaction_read_only = on');
    const factures = (await c.query(`SELECT f.id, f.fichier_nom, f.statut,
        EXISTS (SELECT 1 FROM resultats_controles r WHERE r.facture_id = f.id) AS controlee
      FROM factures f ORDER BY f.id`)).rows;
    const statuts = {};
    for (const f of factures) statuts[f.statut] = (statuts[f.statut] ?? 0) + 1;
    const extractions = (await c.query(`SELECT resultat, code_resultat, coalesce(version_chaine, '—') AS version, count(*)::int AS n
      FROM extractions GROUP BY 1, 2, 3 ORDER BY 1, 2`)).rows;
    const enCours = factures.filter((f) => ['recue', 'en_extraction'].includes(f.statut)).length;
    const aControler = factures.filter((f) => ['extraite', 'en_controle'].includes(f.statut)).length;
    console.log(`Factures : ${factures.length} — ${Object.entries(statuts).map(([s, n]) => `${s} ${n}`).join(', ') || 'aucune'}`);
    console.log(`Extractions : ${extractions.map((e) => `${e.resultat}/${e.code_resultat} (${e.version}) ${e.n}`).join(', ') || 'aucune'}`);
    const ordre = ordreConforme(factures);
    console.log(ordre ? `Ordre de réception : ÉCART — ${ordre}` : 'Ordre de réception : conforme (identifiants croissants dans l\'ordre des noms)');
    console.log(`Contrôlées : ${factures.filter((f) => f.controlee).length} / ${factures.length}`);
    // Réservation interrompue (exécution arrêtée) : reprise par le mécanisme normal,
    // après le délai de reprise des fonctions de réservation (15 minutes, D-082).
    const interrompues = (await c.query(`SELECT fichier_nom, statut, reservee_le,
        to_char((reservee_le + interval '15 minutes') AT TIME ZONE 'Africa/Tunis', 'HH24:MI') AS reprise,
        reservee_le + interval '15 minutes' <= now() AS reprenable
      FROM factures WHERE statut IN ('en_extraction', 'en_controle') ORDER BY id`)).rows;
    for (const f of interrompues) {
      console.log(`Réservation en cours : ${f.fichier_nom} (${f.statut}) depuis ${f.reservee_le.toISOString()} — `
        + `${f.reprenable ? 'reprenable maintenant' : `reprenable à partir de ${f.reprise} (heure de Tunis)`} en relançant le workflow.`);
    }
    if (enCours) console.log(`→ ${enCours} facture(s) encore à extraire : relancer « Réception et extraction » (ou attendre le quota du lendemain).`);
    else if (aControler) console.log(`→ Extraction terminée : lancer une fois « Contrôles » (${aControler} facture(s) à contrôler).`);
    else if (factures.length) console.log('→ Extraction et contrôles terminés : sauvegarder la base, puis mesurer.');
  } finally {
    await c.end();
  }
}

if (process.argv[1]?.endsWith('etat-evaluation.js')) {
  principal().catch((e) => { console.error(e.message); process.exitCode = 1; });
}
