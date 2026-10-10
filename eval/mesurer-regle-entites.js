// Mesure avant/après de la règle signalements_extraction v2 (D-085), sans
// appel au modèle : les contrôles sont rejoués en mémoire sur les extractions
// enregistrées d'une base (contexte_controles), avec la version 1 (tout
// signalement autre que « plusieurs RIB » = avertissement) et la version 2.
// Lot de développement seulement (vérité terrain du lot de développement).
// Usage : node eval/mesurer-regle-entites.js --base <nom> --libelle <texte> --sortie <fichier.md>
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import pg from 'pg';
import { controlerFacture, statutSelonGravite } from '../src/controles/regles.js';
import { deps, lireVerites } from './controles-commun.js';

const arg = (nom) => { const i = process.argv.indexOf(nom); return i > -1 ? process.argv[i + 1] : undefined; };
const RIB = /RIB valides dans le texte source/;

/** Version 1 de la règle, telle qu'elle était avant D-085. */
export function regleV1(ctx) {
  if (!ctx.extraction) return { regle: 'signalements_extraction', resultat: 'non_applicable', gravite: 'info' };
  const s = (ctx.extraction.signalements_code ?? []).filter((x) => !RIB.test(x));
  return s.length ? { regle: 'signalements_extraction', resultat: 'anomalie', gravite: 'avertissement', detail: { signalements: s } }
    : { regle: 'signalements_extraction', resultat: 'ok', gravite: 'info' };
}
const alerte = (r) => (r.resultat === 'anomalie' || r.resultat === 'erreur') && r.gravite !== 'info';

async function principal() {
  if (existsSync('.env')) process.loadEnvFile('.env');
  const base = arg('--base') ?? process.env.MIZAN_DB ?? 'mizan';
  const c = new pg.Client({ host: 'localhost', port: 5432, user: process.env.POSTGRES_USER, password: process.env.POSTGRES_PASSWORD, database: base });
  await c.connect();
  const lignes = [];
  try {
    const verites = new Map(lireVerites('dev').map((v) => [v.id, v]));
    const factures = (await c.query("SELECT id, fichier_nom FROM factures WHERE fichier_nom NOT LIKE '%-essai.%' ORDER BY id")).rows;
    for (const f of factures) {
      const id = f.fichier_nom.replace(/\.\w+$/, '');
      const v = verites.get(id);
      if (!v) continue;
      const { rows: [{ contexte }] } = await c.query('SELECT contexte_controles($1::bigint) AS contexte', [f.id]);
      const v2 = controlerFacture(contexte, deps).resultats;
      const v1 = v2.map((r) => (r.regle === 'signalements_extraction' ? regleV1(contexte) : r));
      const r1 = v1.find((r) => r.regle === 'signalements_extraction');
      const r2 = v2.find((r) => r.regle === 'signalements_extraction');
      lignes.push({
        id, piege: v.anomalies_attendues.length > 0 || Boolean(v.derive_de) || [...verites.values()].some((o) => o.derive_de === id),
        injection: v.robustesse.length > 0, g1: r1.resultat === 'anomalie' ? r1.gravite : r1.resultat, g2: r2.resultat === 'anomalie' ? r2.gravite : r2.resultat,
        statut1: statutSelonGravite(v1), statut2: statutSelonGravite(v2),
        alertes1: v1.filter(alerte).map((r) => r.regle), alertes2: v2.filter(alerte).map((r) => r.regle),
      });
    }
  } finally {
    await c.end();
  }
  // Fausses alertes : factures sans piège ni doublon, hors injection (dont le signalement « plusieurs RIB » est voulu).
  const normales = lignes.filter((l) => !l.piege && !l.injection);
  const fausses = (k) => normales.filter((l) => l[k].length).map((l) => l.id);
  const changees = lignes.filter((l) => l.g1 !== l.g2 || l.statut1 !== l.statut2);
  const t = [
    `# Règle signalements_extraction : version 1 → version 2 (${arg('--libelle') ?? base})`, '',
    `Contrôles rejoués en mémoire sur les extractions enregistrées de la base « ${base} », sans appel au modèle (D-085). `
      + `Factures du lot de développement : ${lignes.length}. Nombres bruts.`, '',
    '| Mesure | Version 1 | Version 2 |', '|---|---|---|',
    `| Signalements d'entités en avertissement | ${lignes.filter((l) => l.g1 === 'avertissement').length} | ${lignes.filter((l) => l.g2 === 'avertissement').length} |`,
    `| Signalements d'entités classés « info » | 0 | ${lignes.filter((l) => l.g2 === 'info').length} |`,
    `| Factures sans piège avec une fausse alerte (hors injection) | ${fausses('alertes1').length} (${fausses('alertes1').join(', ') || '—'}) | ${fausses('alertes2').length} (${fausses('alertes2').join(', ') || '—'}) |`, '',
    '| Facture | Règle v1 | Règle v2 | Statut v1 | Statut v2 |', '|---|---|---|---|---|',
    ...(changees.length ? changees.map((l) => `| ${l.id} | ${l.g1} | ${l.g2} | ${l.statut1} | ${l.statut2} |`) : ['| — | aucune facture ne change | | | |']),
    '', 'Une « info » ne change pas le statut. Les pièges et les doublons ne sont pas concernés par cette règle.', '',
  ];
  const sortie = arg('--sortie');
  if (sortie) { mkdirSync(dirname(sortie), { recursive: true }); writeFileSync(sortie, t.join('\n')); }
  console.log(t.join('\n'));
}

if (process.argv[1]?.endsWith('mesurer-regle-entites.js')) {
  principal().catch((e) => { console.error(e.message); process.exitCode = 1; });
}
