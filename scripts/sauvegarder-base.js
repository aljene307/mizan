// Sauvegarde et restauration de la base métier (D-078). La sauvegarde est
// faite par pg_dump dans le conteneur postgres (format « custom », relu par
// pg_restore) et écrite dans sauvegardes/ (ignoré par Git : la base contient
// des données personnelles, comme l'identifiant Telegram des utilisateurs).
// Une sauvegarde est relue (pg_restore --list) avant d'être déclarée valide.
// Usage :
//   npm run sauvegarder-base                       sauvegarde la base MIZAN_DB
//   npm run sauvegarder-base -- --base mizan_test  autre base
//   npm run sauvegarder-base -- --restaurer sauvegardes/x.dump --dans mizan_restauree
// La restauration refuse d'écraser la base de travail (MIZAN_DB) : elle se
// fait dans une base distincte, à examiner avant toute autre opération.
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

const arg = (nom) => { const i = process.argv.indexOf(nom); return i > -1 ? process.argv[i + 1] : undefined; };
const NOM_BASE = /^[a-z_][a-z0-9_]{0,62}$/;

/** Commande dans le conteneur postgres ; l'entrée et la sortie sont binaires. */
function dansPostgres(script, entree) {
  return spawnSync('docker', ['compose', 'exec', '-T', 'postgres', 'sh', '-c', script],
    { input: entree, maxBuffer: 1024 * 1024 * 1024 });
}

/** Horodatage lisible et triable : 2026-10-10-1452. */
export function horodatage(date = new Date()) {
  const p = (n) => String(n).padStart(2, '0');
  return `${date.getFullYear()}-${p(date.getMonth() + 1)}-${p(date.getDate())}-${p(date.getHours())}${p(date.getMinutes())}`;
}

/** Objets d'une sauvegarde, relus par pg_restore --list (preuve qu'elle est lisible). */
export function listerSauvegarde(chemin) {
  const r = dansPostgres('pg_restore --list', readFileSync(chemin));
  if (r.status !== 0) throw new Error(`sauvegarde illisible : ${r.stderr.toString().trim()}`);
  const lignes = r.stdout.toString().split('\n').filter((l) => /^\d+;/.test(l));
  return { objets: lignes.length, tables: lignes.filter((l) => / TABLE DATA /.test(l)).length };
}

/** Sauvegarde une base ; renvoie le chemin et ce que contient le fichier. */
export function sauvegarder(base, dossier = 'sauvegardes') {
  if (!NOM_BASE.test(base)) throw new Error(`nom de base invalide : ${base}`);
  const r = dansPostgres(`pg_dump -U "$POSTGRES_USER" -d ${base} --format=custom`);
  if (r.status !== 0) throw new Error(`pg_dump a échoué : ${r.stderr.toString().trim()}`);
  mkdirSync(dossier, { recursive: true });
  let chemin = `${dossier}/${base}-${horodatage()}.dump`;
  for (let i = 2; existsSync(chemin); i += 1) chemin = `${dossier}/${base}-${horodatage()}-${i}.dump`;
  writeFileSync(chemin, r.stdout);
  return { chemin, octets: statSync(chemin).size, ...listerSauvegarde(chemin) };
}

/** Restaure une sauvegarde dans une base NEUVE (recréée), jamais dans la base de travail. */
export function restaurer(chemin, base, baseDeTravail = process.env.MIZAN_DB ?? 'mizan') {
  if (!NOM_BASE.test(base)) throw new Error(`nom de base invalide : ${base}`);
  if (base === baseDeTravail) throw new Error(`refus : la restauration ne se fait pas dans la base de travail « ${baseDeTravail} »`);
  const r = dansPostgres(`dropdb -U "$POSTGRES_USER" --if-exists ${base} && createdb -U "$POSTGRES_USER" ${base}`
    + ` && pg_restore -U "$POSTGRES_USER" -d ${base} --no-owner --exit-on-error`, readFileSync(chemin));
  if (r.status !== 0) throw new Error(`restauration en échec : ${r.stderr.toString().trim()}`);
}

function principal() {
  if (existsSync('.env')) process.loadEnvFile('.env');
  const aRestaurer = arg('--restaurer');
  if (aRestaurer) {
    const dans = arg('--dans');
    if (!dans) throw new Error('--dans <base> obligatoire (base distincte de la base de travail)');
    restaurer(aRestaurer, dans);
    console.log(`${aRestaurer} restaurée dans la base « ${dans} ».`);
    return;
  }
  const base = arg('--base') ?? process.env.MIZAN_DB ?? 'mizan';
  const s = sauvegarder(base);
  console.log(`Sauvegarde de « ${base} » : ${s.chemin} (${(s.octets / 1024).toFixed(0)} Kio, ${s.objets} objets, `
    + `${s.tables} tables avec données), relue par pg_restore.`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { principal(); } catch (e) { console.error(e.message); process.exitCode = 1; }
}
