// Recrée la base de test « mizan_test » (vide, toutes migrations appliquées)
// avant les tests d'intégration. La base « mizan » n'est jamais touchée.
// Usage : npm run test:integration   (PostgreSQL doit tourner)
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';

if (existsSync('.env')) process.loadEnvFile('.env');
const { POSTGRES_USER, POSTGRES_PASSWORD } = process.env;
const url = `postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/mizan_test?sslmode=disable`;

const dbmate = (...args) => spawnSync(
  'docker',
  ['compose', 'run', '--rm', '-e', `DATABASE_URL=${url}`, 'dbmate', '--no-dump-schema', ...args],
  { encoding: 'utf8' },
);

dbmate('drop'); // échoue sans conséquence si la base n'existe pas encore
for (const etape of ['create', 'up']) {
  const r = dbmate(etape);
  if (r.status !== 0) {
    console.error(r.stdout, r.stderr);
    process.exit(1);
  }
}
console.log('Base mizan_test recréée.');
