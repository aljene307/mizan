// Remet les factures du lot de DÉVELOPPEMENT en accord avec la configuration
// d'extraction figée (D-053, D-059) : chaque facture dont la dernière
// extraction ne vient pas de la version en service repasse au statut « recue »,
// pour être réextraite par le workflow avec les mêmes fichiers.
// Usage : node scripts/reextraire-lot-dev.js               simulation (rien n'est écrit)
//         node scripts/reextraire-lot-dev.js --appliquer   application
//         [--base mizan_test]
// Garanties :
// - seuls les fichiers du lot dev (data/synthetic/lots.json) sont visés : ni
//   lot de test (D-026), ni copies d'essai (D-054) ;
// - refus si une facture visée a déjà des résultats de contrôle, ou n'est pas
//   au statut « extraite » ou « erreur_extraction » ;
// - une transaction par facture : lignes supprimées (données dérivées, que la
//   nouvelle extraction réinsère), champs extraits remis à vide, statut
//   « recue », entrée « facture.reextraction » au journal d'audit ;
// - les extractions précédentes restent (ajout seul).
// Rôle utilisé : l'administrateur (opération de maintenance, D-059).
import { existsSync, readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import pg from 'pg';
import { VERSION_CHAINE_EXTRACTION } from '../src/extractionWorkflow.js';

const ACTEUR = 'admin:script:reextraire-lot-dev';
const MOTIF = `Mise en accord avec la configuration d'extraction figée (D-053), version de chaîne ${VERSION_CHAINE_EXTRACTION} (D-059)`;
const STATUTS_ADMIS = new Set(['extraite', 'erreur_extraction']);

/** Noms des fichiers du lot de développement. */
export function fichiersLotDev() {
  const lots = JSON.parse(readFileSync('data/synthetic/lots.json', 'utf8'));
  return lots.dev.map((d) => d.fichier.split('/').pop());
}

/**
 * Plan de réextraction : pour chaque fichier visé, l'action prévue et sa raison.
 * @param {pg.Client} client
 * @param {string[]} noms fichiers visés (lot dev)
 * @param {string} version version de chaîne en service
 */
export async function planifierReextraction(client, noms, version) {
  const { rows } = await client.query(`
    SELECT f.id, f.fichier_nom, f.statut,
           (SELECT count(*)::int FROM lignes_facture l WHERE l.facture_id = f.id) AS lignes,
           (SELECT count(*)::int FROM resultats_controles r WHERE r.facture_id = f.id) AS controles,
           e.id AS extraction_id, e.resultat, e.version_chaine
    FROM factures f
    LEFT JOIN LATERAL (SELECT * FROM extractions x WHERE x.facture_id = f.id ORDER BY x.id DESC LIMIT 1) e ON TRUE
    WHERE f.canal_reception = 'dossier' AND f.fichier_nom = ANY($1::text[])
    ORDER BY f.id`, [noms]);
  const plan = rows.map((r) => {
    const aJour = ['valide', 'reutilisee'].includes(r.resultat) && r.version_chaine === version;
    let action = 'reextraire';
    let raison = `dernière extraction n° ${r.extraction_id ?? '—'} (${r.resultat ?? 'aucune'}, version ${r.version_chaine ?? 'antérieure'})`;
    if (aJour) { action = 'ignorer'; raison = `déjà extraite avec la version ${version}`; }
    else if (r.controles > 0) { action = 'refuser'; raison = `${r.controles} résultat(s) de contrôle déjà enregistré(s)`; }
    else if (!STATUTS_ADMIS.has(r.statut)) { action = 'refuser'; raison = `statut « ${r.statut} »`; }
    return { ...r, action, raison };
  });
  const presents = new Set(rows.map((r) => r.fichier_nom));
  return { plan, absents: noms.filter((n) => !presents.has(n)) };
}

/** Applique le plan (refusé en bloc si une facture est « à refuser »). */
export async function appliquerReextraction(client, plan) {
  const refus = plan.filter((p) => p.action === 'refuser');
  if (refus.length) throw new Error(`réextraction refusée : ${refus.map((p) => `${p.fichier_nom} (${p.raison})`).join(' ; ')}`);
  let faites = 0;
  for (const p of plan.filter((x) => x.action === 'reextraire')) {
    await client.query('BEGIN');
    try {
      await client.query('DELETE FROM lignes_facture WHERE facture_id = $1', [p.id]);
      await client.query(`
        UPDATE factures SET statut = 'recue', reservee_le = NULL, type_document = 'facture', facture_origine_id = NULL,
               numero = NULL, date_facture = NULL, date_echeance = NULL, devise = 'TND',
               montant_ht = NULL, montant_tva = NULL, droit_timbre = NULL, montant_ttc = NULL,
               matricule_fiscal_lu = NULL, raison_sociale_lue = NULL, rib_facture = NULL,
               methode_extraction = NULL, extraction_brute = NULL, fournisseur_id = NULL, fournisseur_source = NULL
        WHERE id = $1 AND statut = ANY($2::text[])`, [p.id, [...STATUTS_ADMIS]]);
      await client.query(
        `INSERT INTO journal_audit (acteur, action, entite, entite_id, canal, donnees_avant, donnees_apres, commentaire)
         VALUES ($1, 'facture.reextraction', 'factures', $2, 'dossier', $3, $4, $5)`,
        [ACTEUR, String(p.id),
          { statut: p.statut, extraction_id: p.extraction_id, resultat: p.resultat, version_chaine: p.version_chaine, lignes: p.lignes },
          { statut: 'recue', version_chaine_attendue: VERSION_CHAINE_EXTRACTION }, MOTIF],
      );
      await client.query('COMMIT');
      faites += 1;
    } catch (erreur) {
      await client.query('ROLLBACK');
      throw erreur;
    }
  }
  return faites;
}

async function principal() {
  if (existsSync('.env')) process.loadEnvFile('.env');
  const appliquer = process.argv.includes('--appliquer');
  const indexBase = process.argv.indexOf('--base');
  const base = indexBase > -1 ? process.argv[indexBase + 1] : (process.env.MIZAN_DB ?? 'mizan');
  const client = new pg.Client({
    host: 'localhost', port: 5432, user: process.env.POSTGRES_USER, password: process.env.POSTGRES_PASSWORD, database: base,
  });
  await client.connect();
  try {
    const { plan, absents } = await planifierReextraction(client, fichiersLotDev(), VERSION_CHAINE_EXTRACTION);
    console.log(`Base ${base} — ${appliquer ? 'APPLICATION' : 'SIMULATION (rien n\'est écrit ; --appliquer pour agir)'}`);
    console.log(`Version de chaîne en service : ${VERSION_CHAINE_EXTRACTION}\n`);
    console.log('| Fichier | Statut | Lignes | Action | Raison |\n|---|---|---|---|---|');
    for (const p of plan) console.log(`| ${p.fichier_nom} | ${p.statut} | ${p.lignes} | ${p.action} | ${p.raison} |`);
    const compte = (a) => plan.filter((p) => p.action === a).length;
    console.log(`\nÀ réextraire : ${compte('reextraire')} ; déjà à jour : ${compte('ignorer')} ; refusées : ${compte('refuser')} ; `
      + `fichiers du lot dev absents de la base : ${absents.length}${absents.length ? ` (${absents.join(', ')})` : ''}.`);
    if (appliquer) console.log(`\n${await appliquerReextraction(client, plan)} facture(s) remise(s) au statut « recue ».`);
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
