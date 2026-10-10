// Fichier des ordres d'un lot APPROUVÉ, à signer pour la banque (D-068, C-b1) :
// un CSV (séparateur « ; », virgule décimale, comme le relevé) et un
// récapitulatif lisible. Lecture seule, avec le rôle mizan_lecture : le RIB
// est celui copié du référentiel dans l'ordre (D-058). Aucun format d'échange
// bancaire réel (pas de source fiable sur ceux des banques tunisiennes).
// Usage :
//   npm run exporter-ordres                 liste les lots (numéro, statut, total)
//   npm run exporter-ordres -- --lot <n>    écrit sorties/ordres/lot-<n>.csv et lot-<n>-recapitulatif.txt
// Options : --base <nom> (défaut : MIZAN_DB), --sortie <dossier> (défaut : sorties/ordres).
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import pg from 'pg';
import { enMillimes, formaterMontant } from '../src/montants.js';

const arg = (nom) => { const i = process.argv.indexOf(nom); return i > -1 ? process.argv[i + 1] : undefined; };
const COLONNES = ['lot', 'ordre', 'date_approbation', 'beneficiaire', 'rib_beneficiaire', 'montant', 'devise', 'motif', 'facture'];
const montantCsv = (v) => formaterMontant(enMillimes(v), { milliers: '' });
const champ = (v) => String(v ?? '').replace(/[;\r\n]/g, ' ');

/** CSV des ordres d'un lot : une ligne par ordre, en-tête fixe. */
export function csvOrdres(ordres) {
  const lignes = ordres.map((o) => [o.lot_id, o.ordre_id, o.decide_le.slice(0, 10), o.beneficiaire, o.rib_paiement,
    montantCsv(o.montant), o.devise, o.reference, o.numero].map(champ).join(';'));
  return `${[COLONNES.join(';'), ...lignes].join('\r\n')}\r\n`;
}

/** Récapitulatif à relire avant de signer. */
export function recapitulatif(ordres) {
  const [p] = ordres;
  const total = ordres.reduce((t, o) => t + enMillimes(o.montant), 0);
  return [
    `Lot d'ordres de paiement n° ${p.lot_id} — approuvé le ${p.decide_le.slice(0, 10)}`,
    `${ordres.length} ordre(s), total ${formaterMontant(total)} TND`,
    '',
    ...ordres.map((o) => `- ${o.reference} : ${o.beneficiaire}, ${formaterMontant(enMillimes(o.montant))} ${o.devise}, RIB ${o.rib_paiement}`),
    '',
    'Chaque RIB est celui du référentiel fournisseur (D-058), jamais celui lu sur une facture.',
    'Le motif (FACT …) doit figurer sur le virement : il permet le rapprochement avec le relevé.',
    '',
  ].join('\n');
}

/** Lots existants, une ligne lisible par lot (les numéros ne commencent pas forcément à 1). */
async function listeLots(client) {
  const { rows } = await client.query(`SELECT lot_id, statut_lot, propose_le::date::text AS propose_le, count(*) AS ordres, sum(montant) AS total
    FROM ordres_paiement GROUP BY lot_id, statut_lot, propose_le ORDER BY lot_id`);
  if (!rows.length) return 'Aucun lot.';
  return rows.map((r) => `lot ${r.lot_id} — ${r.statut_lot} — proposé le ${r.propose_le} — ${r.ordres} ordre(s), `
    + `${formaterMontant(enMillimes(r.total))} TND`).join('\n');
}

async function principal() {
  if (existsSync('.env')) process.loadEnvFile('.env');
  const client = new pg.Client({
    host: 'localhost', port: 5432, user: 'mizan_lecture', password: process.env.MIZAN_LECTURE_PASSWORD,
    database: arg('--base') ?? process.env.MIZAN_DB ?? 'mizan',
  });
  const dossier = arg('--sortie') ?? 'sorties/ordres';
  await client.connect();
  try {
    const lot = arg('--lot');
    if (!lot) {
      console.log(await listeLots(client));
      return;
    }
    if (!/^\d+$/.test(lot)) throw new Error(`numéro de lot invalide : « ${lot} »\nLots disponibles :\n${await listeLots(client)}`);
    const { rows } = await client.query(`SELECT lot_id, ordre_id, statut_lot, decide_le::text AS decide_le, beneficiaire, rib_paiement,
        montant, devise, reference, numero FROM ordres_paiement WHERE lot_id = $1 ORDER BY ordre_id`, [Number(lot)]);
    if (!rows.length) throw new Error(`lot ${lot} inconnu.\nLots disponibles :\n${await listeLots(client)}`);
    if (rows[0].statut_lot !== 'approuve') throw new Error(`lot ${lot} ${rows[0].statut_lot} : seul un lot approuvé est exporté`);
    mkdirSync(dossier, { recursive: true });
    writeFileSync(`${dossier}/lot-${lot}.csv`, `﻿${csvOrdres(rows)}`);
    writeFileSync(`${dossier}/lot-${lot}-recapitulatif.txt`, recapitulatif(rows));
    console.log(`${dossier}/lot-${lot}.csv et lot-${lot}-recapitulatif.txt écrits (${rows.length} ordre(s)).`);
  } finally {
    await client.end();
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  principal().catch((e) => { console.error(e.message); process.exitCode = 1; });
}
