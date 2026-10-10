// Sauvegarde et restauration (D-078) : une sauvegarde jamais restaurée ne
// compte pas. La base mizan_test (remplie par les autres fichiers de test)
// est sauvegardée, restaurée dans une base distincte, et comparée table par
// table : factures, décisions, journal d'audit…
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { sauvegarder, restaurer } from '../../scripts/sauvegarder-base.js';

if (existsSync('.env')) process.loadEnvFile('.env');
const dossier = mkdtempSync(join(tmpdir(), 'mizan-sauvegarde-'));
const BASE_RESTAUREE = 'mizan_test_restauree';
const TABLES = ['factures', 'extractions', 'resultats_controles', 'decisions_humaines', 'decisions_referentiel',
  'decisions_rapprochement', 'decisions_lot_paiement', 'decisions_annulation', 'rapprochements', 'journal_audit',
  'utilisateurs', 'adresses_canal', 'notifications'];
const compter = (base) => {
  const sql = TABLES.map((t) => `(SELECT count(*) FROM ${t})`).join(" || '|' || ");
  const r = spawnSync('docker', ['compose', 'exec', '-T', 'postgres', 'sh', '-c',
    `psql -X -tA -U "$POSTGRES_USER" -d ${base} -c "SELECT ${sql}"`], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  return Object.fromEntries(r.stdout.trim().split('|').map((n, i) => [TABLES[i], Number(n)]));
};
after(() => {
  spawnSync('docker', ['compose', 'exec', '-T', 'postgres', 'sh', '-c', `dropdb -U "$POSTGRES_USER" --if-exists ${BASE_RESTAUREE}`]);
  rmSync(dossier, { recursive: true, force: true });
});

test('sauvegarde relue, restaurée dans une autre base, contenu identique table par table', () => {
  const s = sauvegarder('mizan_test', dossier);
  assert.ok(s.octets > 0 && s.tables > 10, `${s.tables} tables avec données`);
  restaurer(s.chemin, BASE_RESTAUREE);
  const origine = compter('mizan_test');
  assert.ok(origine.factures > 0 && origine.journal_audit > 0, 'la base de test contient des données');
  assert.deepEqual(compter(BASE_RESTAUREE), origine);
});

test('la restauration refuse d\'écraser la base de travail', () => {
  assert.throws(() => restaurer('inutile.dump', 'mizan', 'mizan'), /refus : la restauration ne se fait pas dans la base de travail/);
});
