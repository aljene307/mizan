// Grafana (D-070), sur la pile démarrée : configuration Docker et contrôles
// à l'exécution. Aucune assertion n'affiche de mot de passe.
//   - port publié sur 127.0.0.1 seulement ; mot de passe administrateur venu
//     de .env, jamais « admin » ni « change-me » ;
//   - accès anonyme refusé, identifiants par défaut refusés ;
//   - source de données en mizan_lecture ; chaque requête du tableau de bord
//     s'exécute ; une écriture est refusée par la base.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';

if (existsSync('.env')) process.loadEnvFile('.env');
const URL_GRAFANA = 'http://127.0.0.1:3000';
const admin = `Basic ${Buffer.from(`admin:${process.env.GRAFANA_ADMIN_PASSWORD}`).toString('base64')}`;
const appel = (chemin, { auth, corps } = {}) => fetch(`${URL_GRAFANA}${chemin}`, {
  method: corps ? 'POST' : 'GET',
  headers: { ...(auth ? { Authorization: auth } : {}), ...(corps ? { 'Content-Type': 'application/json' } : {}) },
  body: corps ? JSON.stringify(corps) : undefined,
});
const requeteSql = (rawSql) => ({ queries: [{ refId: 'A', datasource: { uid: 'mizan-lecture' }, rawSql, format: 'table' }] });

test('configuration Docker : port sur 127.0.0.1 seulement, anonyme désactivé, mot de passe ni par défaut ni d\'exemple', () => {
  const r = spawnSync('docker', ['compose', 'config', '--format', 'json'], { encoding: 'utf8' });
  assert.equal(r.status, 0, 'docker compose config');
  const g = JSON.parse(r.stdout).services.grafana;
  assert.deepEqual(g.ports.map((p) => [p.host_ip, String(p.published), p.target]), [['127.0.0.1', '3000', 3000]]);
  assert.equal(g.environment.GF_AUTH_ANONYMOUS_ENABLED, 'false');
  assert.equal(g.environment.GF_USERS_ALLOW_SIGN_UP, 'false');
  const mdp = process.env.GRAFANA_ADMIN_PASSWORD ?? '';
  assert.ok(mdp.length >= 20 && !['admin', 'change-me'].includes(mdp), 'mot de passe administrateur fort, défini dans .env');
  assert.equal(g.environment.GF_SECURITY_ADMIN_PASSWORD === mdp, true, 'le conteneur reçoit celui de .env');
  assert.equal(g.environment.TELEGRAM_BOT_TOKEN, undefined);
  assert.equal(g.environment.POSTGRES_PASSWORD, undefined, 'aucun accès administrateur à la base');
});

test('à l\'exécution : anonyme refusé, identifiants par défaut refusés, administrateur accepté', async () => {
  assert.equal((await appel('/api/health')).status, 200);
  assert.equal((await appel('/api/dashboards/uid/mizan-restitution')).status, 401, 'accès anonyme');
  const defaut = `Basic ${Buffer.from('admin:admin').toString('base64')}`;
  assert.equal((await appel('/api/dashboards/uid/mizan-restitution', { auth: defaut })).status, 401, 'admin / admin');
  assert.equal((await appel('/api/dashboards/uid/mizan-restitution', { auth: admin })).status, 200);
});

test('source de données : mizan_lecture, connexion valide, une seule source', async () => {
  const sources = await (await appel('/api/datasources', { auth: admin })).json();
  assert.deepEqual(sources.map((s) => [s.uid, s.user, s.readOnly]), [['mizan-lecture', 'mizan_lecture', true]]);
  const sante = await (await appel('/api/datasources/uid/mizan-lecture/health', { auth: admin })).json();
  assert.equal(sante.status, 'OK');
});

test('chaque requête du tableau de bord s\'exécute avec mizan_lecture', async () => {
  const tableau = JSON.parse(readFileSync('grafana/dashboards/mizan-restitution.json', 'utf8'));
  for (const p of tableau.panels.filter((x) => x.targets.length)) {
    const r = await (await appel('/api/ds/query', { auth: admin, corps: requeteSql(p.targets[0].rawSql) })).json();
    assert.equal(r.results.A.status, 200, `${p.title} : ${r.results.A.error ?? ''}`);
  }
  const qui = await (await appel('/api/ds/query', { auth: admin, corps: requeteSql('SELECT current_user::text AS qui') })).json();
  assert.deepEqual(qui.results.A.frames[0].data.values, [['mizan_lecture']]);
});

test('par Grafana, une écriture ou une lecture hors restitution est refusée par la base', async () => {
  for (const sql of ['DELETE FROM public.factures', 'SELECT * FROM public.fournisseur_ribs', 'CREATE TABLE restitution.x (a int)']) {
    const r = await (await appel('/api/ds/query', { auth: admin, corps: requeteSql(sql) })).json();
    assert.notEqual(r.results.A.status, 200, sql);
    // 42501 : droit refusé ; 25006 : session en lecture seule (défense en profondeur, D-068).
    assert.match(r.results.A.error, /SQLSTATE (42501|25006)/, sql);
  }
});
