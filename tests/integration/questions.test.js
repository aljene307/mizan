// Catalogue des questions (D-068, B2) exécuté RÉELLEMENT avec le rôle
// mizan_lecture (vraie connexion : réglages de session appliqués) sur la
// base mizan_test : chaque requête s'exécute et rend une ligne « lignes » ;
// un paramètre hostile reste une valeur ; rien d'autre n'est lisible.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import pg from 'pg';
import { CATALOGUE, interpreter, requeteQuestion } from '../../src/questions/catalogue.js';
import { EXEMPLES_PARAMETRES } from '../exemples-questions.js';

if (existsSync('.env')) process.loadEnvFile('.env');
const lecture = new pg.Client({
  host: 'localhost', port: 5432, user: 'mizan_lecture', password: process.env.MIZAN_LECTURE_PASSWORD, database: 'mizan_test',
});
before(() => lecture.connect());
after(() => lecture.end());
const executer = async (interpretation) => {
  const { sql, valeurs } = requeteQuestion(interpretation);
  return (await lecture.query(sql, valeurs)).rows;
};

test('chaque question du catalogue s\'exécute en mizan_lecture et rend exactement une ligne « lignes » (tableau)', async () => {
  for (const q of CATALOGUE) {
    const rows = await executer(interpreter({ question: q.id, parametres: EXEMPLES_PARAMETRES[q.id] }));
    assert.equal(rows.length, 1, q.id);
    assert.ok(Array.isArray(rows[0].lignes), q.id);
  }
  assert.deepEqual(await executer({ code: 'hors_catalogue' }), [{ lignes: [] }]);
});

test('un paramètre hostile reste une valeur : aucune erreur, aucun effet, rien trouvé', async () => {
  const rows = await executer(interpreter({ question: 'du_a_un_fournisseur', parametres: { fournisseur: "x'); DELETE FROM factures; --" } }));
  assert.deepEqual(rows, [{ lignes: [] }]);
  const e = await executer(interpreter({ question: 'etat_facture', parametres: { numero: "' OR '1'='1" } }));
  assert.deepEqual(e, [{ lignes: [] }]);
});

test('la session de lecture ne voit que la restitution : la base refuse le reste', async () => {
  await assert.rejects(lecture.query('SELECT count(*) FROM public.questions'), /permission denied/);
  await assert.rejects(lecture.query('SELECT count(*) FROM public.utilisateurs'), /permission denied/);
  await assert.rejects(lecture.query("UPDATE echeancier SET etat = 'payee'"), /read-only|cannot update|permission denied/);
});
