import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  diviserArrondi, enMillimes, versDinars, montantLigneHt, montantTva, formaterMontant,
} from '../src/montants.js';

test('diviserArrondi arrondit 0,5 en s\'éloignant de zéro', () => {
  assert.equal(diviserArrondi(5n, 2n), 3n);
  assert.equal(diviserArrondi(-5n, 2n), -3n);
  assert.equal(diviserArrondi(4n, 3n), 1n);
  assert.equal(diviserArrondi(5n, 3n), 2n);
  assert.throws(() => diviserArrondi(1n, 0n), RangeError);
});

test('enMillimes convertit sans erreur de virgule flottante', () => {
  assert.equal(enMillimes('1234.5'), 1234500);
  assert.equal(enMillimes(0.1 + 0.2), 300);
  assert.equal(enMillimes(19), 19000);
  assert.equal(enMillimes('-2.125'), -2125);
  assert.equal(enMillimes('7.000000'), 7000);
});

test('enMillimes refuse plus de 3 décimales et les textes invalides', () => {
  assert.throws(() => enMillimes('1.2345'), RangeError);
  assert.throws(() => enMillimes('1,5'), TypeError);
  assert.throws(() => enMillimes('abc'), TypeError);
});

test('versDinars est l\'inverse de enMillimes', () => {
  assert.equal(versDinars(1234500), 1234.5);
  assert.equal(versDinars(1), 0.001);
  assert.equal(enMillimes(versDinars(987654321)), 987654321);
});

test('montantLigneHt : quantité × prix unitaire arrondi au millime', () => {
  assert.equal(montantLigneHt(3000, 12500), 37500); // 3 × 12,500
  assert.equal(montantLigneHt(2500, 1333), 3333); // 2,5 × 1,333 = 3,3325 -> 3,333
  assert.equal(montantLigneHt(1500, 1001), 1502); // 1,5 × 1,001 = 1,5015 -> 1,502
});

test('montantTva : arrondi au millime, taux décimaux acceptés', () => {
  assert.equal(montantTva(100000, 19), 19000);
  assert.equal(montantTva(12345, 19), 2346); // 2,34555 -> 2,346
  assert.equal(montantTva(1000, 7), 70);
  assert.equal(montantTva(1000, 7.5), 75);
  assert.equal(montantTva(0, 19), 0);
});

test('formaterMontant : séparateur de milliers et décimale paramétrables', () => {
  assert.equal(formaterMontant(1234500, { milliers: ' ' }), '1 234,500');
  assert.equal(formaterMontant(5, { milliers: ' ' }), '0,005');
  assert.equal(formaterMontant(1234567890, { milliers: '.', decimale: ',' }), '1.234.567,890');
  assert.equal(formaterMontant(-1500, { milliers: '', decimale: '.' }), '-1.500');
});
