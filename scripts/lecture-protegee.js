// Lecture de fichiers protégée (D-026, D-078) : le lot de test est réservé à
// l'évaluation ; aucun script de reconstruction ou d'export ne doit le lire.
// Toute lecture de ces scripts passe par ici, et un test le vérifie.
import { readFileSync } from 'node:fs';
import { resolve, sep } from 'node:path';

const DOSSIER_INTERDIT = resolve('data/synthetic/test');

/** Vrai si le chemin désigne le lot de test (ou un fichier dedans). */
export function estDansLotTest(chemin) {
  const absolu = resolve(chemin);
  return absolu === DOSSIER_INTERDIT || absolu.startsWith(`${DOSSIER_INTERDIT}${sep}`);
}

/** readFileSync, sauf pour le lot de test : refus explicite. */
export function lireFichier(chemin, encodage) {
  if (estDansLotTest(chemin)) throw new Error(`lecture refusée : ${chemin} appartient au lot de test (D-026)`);
  return readFileSync(chemin, encodage);
}

/** Documents du lot de DÉVELOPPEMENT seulement (lots.json : la partie « test » n'est jamais renvoyée). */
export function documentsDev() {
  const lots = JSON.parse(lireFichier('data/synthetic/lots.json', 'utf8'));
  return lots.dev.map((d) => ({ id: d.id, fichier: `data/synthetic/${d.fichier}`, format: d.format, type_document: d.type_document }));
}
