// Second relevé de démonstration (D-068, D-069) : il prolonge le dernier
// relevé importé et contient
//   - le paiement de chaque ordre approuvé encore à exécuter, avec son motif
//     (FACT …) et une commission de virement ;
//   - UNE SORTIE SANS ORDRE : le paiement d'une facture approuvée qu'aucun
//     ordre ne couvre, au libellé aussi plausible que les autres.
// Il est écrit dans data/demo/ (ignoré par Git) : il ne touche ni aux données
// synthétiques, ni à leur vérité terrain, ni aux mesures. Lecture seule, avec
// le rôle mizan_lecture. Pour l'importer : le copier dans data/entrant/releves/.
// Usage : npm run generer-releve-demo
// Options : --base <nom> (défaut : MIZAN_DB), --sortie <dossier> (défaut : data/demo).
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import pg from 'pg';
import { enMillimes, formaterMontant } from '../src/montants.js';
import { abreviation } from '../src/rapprochement/appariement.js';

const arg = (nom) => { const i = process.argv.indexOf(nom); return i > -1 ? process.argv[i + 1] : undefined; };
const COMMISSION_VIREMENT = 1.2;   // comme dans le relevé synthétique
const ENTETE = 'date_operation;date_valeur;libelle;reference;debit;credit;solde';
const montantCsv = (millimes) => formaterMontant(millimes, { milliers: '' });
const dateCsv = (iso) => `${iso.slice(8, 10)}/${iso.slice(5, 7)}/${iso.slice(0, 4)}`;
const lendemain = (iso) => new Date(Date.parse(`${iso}T00:00:00Z`) + 86400000).toISOString().slice(0, 10);

/**
 * Texte CSV du relevé de démonstration.
 * @param {{soldeInitial: string|number, dateReleve: string, ordres: object[], sansOrdre: object|null}} e
 *   ordres : { numero, beneficiaire, reste_a_executer, decide_le (AAAA-MM-JJ) } ;
 *   sansOrdre : { numero, fournisseur, reste_a_payer } ou null.
 * @returns {{csv: string, operations: number, soldeFinal: number}}
 */
export function construireReleveDemo({ soldeInitial, dateReleve, ordres, sansOrdre }) {
  // Aucune opération avant le lendemain du dernier relevé, ni avant l'approbation.
  const debut = lendemain(dateReleve);
  const operations = [];
  for (const o of ordres) {
    const date = o.decide_le > debut ? o.decide_le : debut;
    operations.push({ date, libelle: `VIR EMIS ${abreviation(o.beneficiaire)} FACT ${o.numero}`, debit: enMillimes(o.reste_a_executer) });
    operations.push({ date, libelle: 'COMMISSION SUR VIREMENT', debit: enMillimes(COMMISSION_VIREMENT) });
  }
  if (sansOrdre) {
    const date = operations.reduce((d, op) => (op.date > d ? op.date : d), debut);
    operations.push({ date, libelle: `VIR EMIS ${abreviation(sansOrdre.fournisseur)} FACT ${sansOrdre.numero}`, debit: enMillimes(sansOrdre.reste_a_payer) });
    operations.push({ date, libelle: 'COMMISSION SUR VIREMENT', debit: enMillimes(COMMISSION_VIREMENT) });
  }
  operations.sort((a, b) => a.date.localeCompare(b.date));   // tri stable : ordre d'insertion conservé
  let solde = enMillimes(soldeInitial);
  const lignes = operations.map((op, i) => {
    solde -= op.debit;
    const reference = `OP${op.date.replaceAll('-', '')}${String(9001 + i)}`;
    return [dateCsv(op.date), dateCsv(op.date), op.libelle, reference, montantCsv(op.debit), '', montantCsv(solde)].join(';');
  });
  return { csv: `${[ENTETE, ...lignes].join('\n')}\n`, operations: operations.length, soldeFinal: solde };
}

async function principal() {
  if (existsSync('.env')) process.loadEnvFile('.env');
  const client = new pg.Client({
    host: 'localhost', port: 5432, user: 'mizan_lecture', password: process.env.MIZAN_LECTURE_PASSWORD,
    database: arg('--base') ?? process.env.MIZAN_DB ?? 'mizan',
  });
  const dossier = arg('--sortie') ?? 'data/demo';
  await client.connect();
  try {
    const { rows: [dernier] } = await client.query(
      `SELECT solde_final, date_fin::text AS date_fin FROM releves WHERE devise = 'TND' ORDER BY date_fin DESC, releve_id DESC LIMIT 1`);
    if (!dernier) throw new Error('aucun relevé importé : importer d\'abord le relevé synthétique');
    const { rows: ordres } = await client.query(
      `SELECT numero, beneficiaire, reste_a_executer, decide_le::date::text AS decide_le FROM ordres_paiement
       WHERE statut_lot = 'approuve' AND reste_a_executer > 0 AND current_date <= expire_le ORDER BY decide_le, ordre_id`);
    // Facture approuvée qu'aucun ordre (approuvé ou en attente) ne couvre : la plus lointaine.
    const { rows: [sansOrdre] } = await client.query(
      `SELECT e.numero, e.fournisseur, e.reste_a_payer FROM echeancier e
       WHERE e.devise = 'TND' AND e.etat = 'non_payee'
         AND NOT EXISTS (SELECT 1 FROM ordres_paiement o WHERE o.facture_id = e.facture_id AND o.statut_lot IN ('approuve', 'propose'))
       ORDER BY e.date_echeance DESC NULLS LAST, e.facture_id LIMIT 1`);
    if (!ordres.length) console.warn('Aucun ordre approuvé à exécuter : le relevé ne contiendra que la sortie sans ordre.');
    if (!sansOrdre) console.warn('Aucune facture hors ordre : pas de sortie sans ordre dans ce relevé.');
    const r = construireReleveDemo({ soldeInitial: dernier.solde_final, dateReleve: dernier.date_fin, ordres, sansOrdre: sansOrdre ?? null });
    if (!r.operations) throw new Error('rien à mettre dans le relevé');
    mkdirSync(dossier, { recursive: true });
    const chemin = `${dossier}/releve-demo-${new Date().toISOString().slice(0, 10)}.csv`;
    writeFileSync(chemin, r.csv);
    console.log(`${chemin} : ${r.operations} opération(s), dont ${ordres.length} paiement(s) d'ordres`
      + `${sansOrdre ? ` et 1 sortie sans ordre (facture ${sansOrdre.numero})` : ''} ; solde final ${formaterMontant(r.soldeFinal)} TND.`);
  } finally {
    await client.end();
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  principal().catch((e) => { console.error(e.message); process.exitCode = 1; });
}
