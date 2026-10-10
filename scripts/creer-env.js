// Création de .env à partir de .env.example, sans rien saisir : chaque
// « change-me » est remplacé par un secret aléatoire (lettres et chiffres,
// utilisables dans une URL de connexion). La clé Gemini et le jeton Telegram
// restent vides : la démonstration n'en a pas besoin (base reconstruite sans
// appel au modèle ; la passerelle répond « jeton non configuré »).
// Sans dépendance : se lance avant npm install, sous Windows, macOS ou Linux.
// Usage : node scripts/creer-env.js     (refuse d'écraser un .env existant)
import { randomInt } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';

const ALPHABET = 'abcdefghijklmnopqrstuvwxyz0123456789';
export const LAISSES_VIDES = Object.freeze(['GEMINI_API_KEY', 'TELEGRAM_BOT_TOKEN']);

export function secretAleatoire(longueur = 40) {
  return Array.from({ length: longueur }, () => ALPHABET[randomInt(ALPHABET.length)]).join('');
}

/** Contenu de .env : lignes et commentaires de l'exemple, « change-me » remplacés. */
export function contenuEnv(exemple) {
  return exemple.replace(/^([A-Z0-9_]+)=change-me[ \t]*$/gm,
    (_, cle) => `${cle}=${LAISSES_VIDES.includes(cle) ? '' : secretAleatoire()}`);
}

if (process.argv[1]?.endsWith('creer-env.js')) {
  if (existsSync('.env')) {
    console.error('.env existe déjà : rien n\'est modifié (supprimer le fichier pour en créer un nouveau).');
    process.exitCode = 1;
  } else {
    writeFileSync('.env', contenuEnv(readFileSync('.env.example', 'utf8')));
    console.log(`.env créé : secrets aléatoires ; ${LAISSES_VIDES.join(' et ')} laissés vides (à remplir pour les scripts de mesure et pour Telegram).`);
  }
}
