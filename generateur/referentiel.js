// Données de base du référentiel fictif (docs/decisions.md D-027).
// Raisons sociales inventées ; villes réelles ; adresses e-mail sous le
// domaine réservé « .example » (RFC 2606). Les identifiants (matricule
// fiscal, RIB) sont générés par modele.js dans des plages non attribuables.

export const BANQUE_FICTIVE = { code: '99', nom: 'Banque Démo 99' };

export const ENTREPRISE = {
  code: 'CLIENT',
  raison_sociale: 'Société Démo Mizan SARL',
  adresse: '12, rue de l\'Olivier, 2013 Ben Arous',
};

// Taux de TVA : on référence une CLÉ de config_fiscale, jamais une valeur.
// L'attribution d'un taux à un article est arbitraire (D-029).
const N = 'tva.taux_normal';
const R = 'tva.taux_reduit';
const I = 'tva.taux_intermediaire';

// [désignation, unité, prix min, prix max (TND), clé de taux, quantité min, quantité max, décimales de quantité]
const CATALOGUES = {
  papeterie: [
    ['Ramette papier A4 80 g (500 feuilles)', 'u', 9, 14, N, 5, 60, 0],
    ['Classeur à levier dos 75 mm', 'u', 3.2, 6.5, N, 10, 80, 0],
    ['Stylo bille bleu (boîte de 50)', 'bte', 18, 32, N, 1, 10, 0],
    ['Registre comptable 200 pages', 'u', 12, 25, R, 2, 12, 0],
    ['Enveloppes kraft C4 (paquet de 250)', 'pqt', 35, 60, N, 1, 8, 0],
    ['Cartouche toner noir compatible', 'u', 65, 140, N, 1, 10, 0],
  ],
  informatique: [
    ['Ordinateur portable 15" i5 16 Go', 'u', 1900, 2900, N, 1, 4, 0],
    ['Écran 24" Full HD', 'u', 380, 620, N, 1, 6, 0],
    ['Licence logiciel de gestion (1 an)', 'u', 450, 1200, N, 1, 5, 0],
    ['Disque SSD 1 To', 'u', 210, 340, N, 1, 8, 0],
    ['Intervention technicien', 'h', 45, 85, N, 1, 16, 1],
    ['Câble réseau Cat6 (rouleau 305 m)', 'u', 260, 420, N, 1, 3, 0],
  ],
  nettoyage: [
    ['Nettoyage des locaux (forfait mensuel)', 'mois', 900, 1800, N, 1, 1, 0],
    ['Nettoyage vitrerie', 'm²', 1.8, 3.5, N, 80, 400, 0],
    ['Produits d\'entretien (lot)', 'lot', 60, 180, N, 1, 6, 0],
    ['Désinfection des sanitaires', 'u', 120, 260, N, 1, 4, 0],
  ],
  transport: [
    ['Transport marchandises Tunis - Sfax', 'voyage', 350, 750, I, 1, 6, 0],
    ['Transport marchandises Tunis - Sousse', 'voyage', 220, 480, I, 1, 8, 0],
    ['Manutention', 'h', 25, 45, N, 2, 20, 1],
    ['Location camion avec chauffeur', 'jour', 420, 680, N, 1, 5, 0],
  ],
  emballage: [
    ['Carton double cannelure 60x40x40', 'u', 2.1, 3.9, N, 100, 1500, 0],
    ['Film étirable 23 µm (rouleau)', 'u', 18, 29, N, 10, 120, 0],
    ['Palette bois 120x80', 'u', 22, 38, N, 10, 150, 0],
    ['Ruban adhésif imprimé (lot de 36)', 'lot', 55, 95, N, 1, 20, 0],
    ['Étiquettes adhésives (rouleau de 1000)', 'u', 14, 26, N, 5, 60, 0],
  ],
  maintenance: [
    ['Maintenance préventive compresseur', 'u', 380, 950, N, 1, 2, 0],
    ['Main-d\'œuvre mécanicien', 'h', 35, 60, N, 2, 24, 1],
    ['Roulement à billes 6205', 'u', 14, 32, N, 2, 30, 0],
    ['Huile hydraulique ISO 46', 'L', 6.5, 11, N, 20, 200, 0],
  ],
  electricite: [
    ['Câble électrique 3G2,5 (couronne 100 m)', 'u', 140, 230, N, 1, 10, 0],
    ['Disjoncteur différentiel 40 A', 'u', 85, 160, N, 1, 12, 0],
    ['Projecteur LED 100 W', 'u', 70, 150, N, 2, 20, 0],
    ['Installation électrique', 'h', 30, 55, N, 4, 40, 1],
  ],
  imprimerie: [
    ['Impression flyers A5 quadri', 'mille', 75, 140, N, 1, 20, 0],
    ['Cartes de visite (boîte de 500)', 'bte', 35, 70, N, 1, 10, 0],
    ['Brochure 16 pages', 'u', 2.5, 5.5, N, 100, 2000, 0],
    ['Infographie et mise en page', 'h', 40, 75, N, 1, 12, 1],
  ],
  telecom: [
    ['Abonnement fibre professionnelle', 'mois', 150, 320, N, 1, 3, 0],
    ['Forfait mobile flotte (par ligne)', 'mois', 25, 60, N, 3, 25, 0],
    ['Frais de mise en service', 'u', 50, 150, N, 1, 1, 0],
  ],
  mobilier: [
    ['Bureau opérateur 160x80', 'u', 650, 1350, N, 1, 50, 0],
    ['Fauteuil ergonomique', 'u', 380, 890, N, 1, 50, 0],
    ['Armoire métallique 2 portes', 'u', 520, 990, N, 1, 20, 0],
    ['Table de réunion 10 places', 'u', 1400, 2800, N, 1, 4, 0],
  ],
  securite: [
    ['Gardiennage de nuit (forfait mensuel)', 'mois', 2200, 3800, N, 1, 1, 0],
    ['Agent de sécurité événementiel', 'h', 14, 22, N, 8, 60, 0],
    ['Extincteur poudre 6 kg', 'u', 85, 140, N, 1, 15, 0],
  ],
  agro: [
    ['Bocaux verre 370 ml (carton de 12)', 'ctn', 9, 16, N, 20, 300, 0],
    ['Capsules twist-off 63 mm (carton de 1000)', 'ctn', 95, 160, N, 1, 15, 0],
    ['Sel alimentaire (sac de 25 kg)', 'sac', 9, 15, R, 5, 60, 0],
    ['Sacs kraft alimentaires (lot de 500)', 'lot', 120, 210, N, 1, 10, 0],
  ],
};

// modele : mise en page (rendu.js) ; numero : format de numérotation ;
// delai : jours entre facture et échéance ; poids : fréquence relative.
export const FOURNISSEURS_BASE = [
  { code: 'F01', raison_sociale: 'Papeterie Ennour Bureautique', adresse: '45, avenue de la Liberté, 1002 Tunis', secteur: 'papeterie', modele: 'classique', numero: 'FA-{AAAA}-{N4}', delai: 30, poids: 4 },
  { code: 'F02', raison_sociale: 'InfoSahel Systèmes', adresse: '8, rue Ibn Khaldoun, 4000 Sousse', secteur: 'informatique', modele: 'moderne', numero: 'ISS{AA}{N4}', delai: 30, poids: 3 },
  { code: 'F03', raison_sociale: 'Yasmine Services Nettoyage', adresse: '17, rue des Jasmins, 2080 Ariana', secteur: 'nettoyage', modele: 'ticket', numero: '{AAAA}/{N3}', delai: 0, poids: 3 },
  { code: 'F04', raison_sociale: 'Trans-Cap Logistique', adresse: 'Route de Hammamet km 3, 8000 Nabeul', secteur: 'transport', modele: 'serif', numero: 'TCL-{N5}', delai: 60, poids: 3 },
  { code: 'F05', raison_sociale: 'Emballages Kerkennah', adresse: 'Zone industrielle Poudrière, 3000 Sfax', secteur: 'emballage', modele: 'classique', numero: 'F{AAAA}{N4}', delai: 60, poids: 3 },
  { code: 'F06', raison_sociale: 'Bizerte Nord Maintenance Industrielle', adresse: '3, rue de Mateur, 7000 Bizerte', secteur: 'maintenance', modele: 'serif', numero: 'BNM/{AAAA}/{N3}', delai: 30, poids: 2 },
  { code: 'F07', raison_sociale: 'Électricité Générale Hammamet', adresse: '22, avenue de la République, 8050 Hammamet', secteur: 'electricite', modele: 'ticket', numero: 'EGH {N4}', delai: 30, poids: 2 },
  { code: 'F08', raison_sociale: 'El Manar Graphique', adresse: '9, rue d\'Irak, 2092 El Manar', secteur: 'imprimerie', modele: 'moderne', numero: 'FACT-{AAAA}-{N3}', delai: 30, poids: 2 },
  { code: 'F09', raison_sociale: 'Médina Connect Télécom', adresse: '61, rue de Rome, 1000 Tunis', secteur: 'telecom', modele: 'classique', numero: 'MC{AAAA}-{N5}', delai: 0, poids: 3 },
  { code: 'F10', raison_sociale: 'Atlas Bureau Mobilier', adresse: 'Route de Sousse, 5000 Monastir', secteur: 'mobilier', modele: 'moderne', numero: 'ABM-{N4}', delai: 60, poids: 1 },
  { code: 'F11', raison_sociale: 'Oasis Gardiennage et Sécurité', adresse: '14, avenue Farhat Hached, 6000 Gabès', secteur: 'securite', modele: 'serif', numero: 'OGS-{AA}-{N3}', delai: 30, poids: 2 },
  { code: 'F12', raison_sociale: 'Mejerda Agro-Fournitures', adresse: 'Avenue de l\'Environnement, 9000 Béja', secteur: 'agro', modele: 'ticket', numero: 'MAF{N5}', delai: 60, poids: 3 },
];

// Fournisseurs absents du référentiel (piège « fournisseur_inconnu »).
export const FOURNISSEURS_INCONNUS_BASE = [
  { code: 'X01', raison_sociale: 'Djerba Express Fournitures', adresse: 'Route de Midoun, 4180 Djerba', secteur: 'papeterie', modele: 'serif', numero: 'DEF-{N4}', delai: 30, poids: 0 },
  { code: 'X02', raison_sociale: 'Kairouan Pro Équipement', adresse: '5, rue des Aghlabides, 3100 Kairouan', secteur: 'electricite', modele: 'classique', numero: 'KPE{AAAA}{N3}', delai: 30, poids: 0 },
];

/**
 * Catalogue d'articles d'un secteur, sous forme d'objets.
 * @param {string} secteur
 */
export function catalogue(secteur) {
  return CATALOGUES[secteur].map(([designation, unite, prixMin, prixMax, cleTaux, qMin, qMax, decimales]) => ({
    designation, unite, prixMin, prixMax, cleTaux, qMin, qMax, decimales,
  }));
}
