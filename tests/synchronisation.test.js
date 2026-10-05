// Le code des nœuds Code des workflows exportés doit être identique aux
// fonctions de src/ (D-041). Ce test échoue si quelqu'un modifie le code dans
// l'interface de n8n puis réexporte le workflow sans passer par src/.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import vm from 'node:vm';
import { synchroniserWorkflow, transformerSource } from '../scripts/synchroniser-noeuds.js';
import { validerExtraction } from '../src/validationExtraction.js';

const lire = (chemin) => readFileSync(chemin, 'utf8');
const exemple = JSON.parse(lire('tests/fixtures/workflow-exemple.json'));
const workflows = readdirSync('workflows').filter((f) => f.endsWith('.json'));

test('chaque nœud Code des workflows exportés est synchronisé avec src/', () => {
  for (const fichier of workflows) {
    const { regions } = synchroniserWorkflow(JSON.parse(lire(`workflows/${fichier}`)), lire);
    for (const r of regions) {
      assert.ok(r.aJour, `${fichier} › ${r.noeud} › ${r.chemin} : lancer « npm run synchroniser-noeuds »`);
    }
  }
});

test('un nœud Code périmé est détecté, puis remis à jour par le script', () => {
  const avant = synchroniserWorkflow(exemple, lire);
  assert.deepEqual(avant.regions.map((r) => r.aJour), [false, false], 'les deux régions de l\'exemple sont périmées');
  const apres = synchroniserWorkflow(avant.workflow, lire);
  assert.deepEqual(apres.regions.map((r) => r.aJour), [true, true], 'après synchronisation, plus d\'écart');
  assert.ok(apres.workflow.nodes[0].parameters.jsCode.endsWith('return [{ json: resultat }];\n'), 'le code hors région est conservé');
  assert.deepEqual(apres.workflow.nodes[1], exemple.nodes[1], 'les autres nœuds ne sont pas touchés');
});

test('une modification à la main dans une région synchronisée est détectée', () => {
  const { workflow } = synchroniserWorkflow(exemple, lire);
  workflow.nodes[0].parameters.jsCode = workflow.nodes[0].parameters.jsCode.replace('a plus de', 'a plus que');
  const { regions } = synchroniserWorkflow(workflow, lire);
  assert.equal(regions.find((r) => r.chemin === 'src/validationExtraction.js').aJour, false);
});

test('le code généré s\'exécute comme dans n8n et donne le même résultat que src/', async () => {
  const { workflow } = synchroniserWorkflow(exemple, lire);
  const verite = JSON.parse(lire('data/synthetic/dev/verite/D001.json')).extraction;
  const schema = JSON.parse(lire('src/schemas/extraction-facture.schema.json'));
  for (const donnees of [verite, { ...verite, devise: 'tnd' }]) {
    // Un nœud Code est le corps d'une fonction asynchrone qui reçoit $json.
    const contexte = vm.createContext({ $json: { donnees } });
    const corps = `(async () => {\n${workflow.nodes[0].parameters.jsCode}\n})()`;
    const [{ json }] = await vm.runInContext(corps, contexte);
    assert.deepEqual(JSON.parse(JSON.stringify(json)), validerExtraction(schema, donnees));
  }
});

test('transformation : « export » retiré, import refusé, constante JSON nommée', () => {
  const sortie = transformerSource('src/validationExtraction.js', undefined, lire);
  assert.ok(!/^export/m.test(sortie));
  assert.match(sortie, /^function validerExtraction/m);
  const faux = () => 'import x from "y";\nexport function f() {}';
  assert.throws(() => transformerSource('src/faux.js', undefined, faux), /ne peut pas importer/);
  assert.throws(() => transformerSource('src/prompts-versions.json', undefined, lire), /as NOM_CONSTANTE/);
  assert.match(transformerSource('src/prompts-versions.json', 'VERSIONS', lire), /^const VERSIONS = \{/);
});

test('les modules de src/ destinés aux nœuds Code sont autonomes (sans import)', () => {
  for (const chemin of ['src/validationExtraction.js', 'src/promptExtraction.js', 'src/schemaFournisseur.js']) {
    assert.doesNotThrow(() => transformerSource(chemin, undefined, lire), chemin);
  }
});
