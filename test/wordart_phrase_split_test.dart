import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/wordart/parse_texts.dart';

void main() {
  test('splits pasted lists on separator characters', () {
    expect(splitPhrases('Raat Bhar • Laung Da Lashkara • Dard-E-Disco • What Jhumka?'),
        ['Raat Bhar', 'Laung Da Lashkara', 'Dard-E-Disco', 'What Jhumka?']);
    expect(splitPhrases('mom | dad | home'), ['mom', 'dad', 'home']);
    expect(splitPhrases('Ana; Mila;  Iva'), ['Ana', 'Mila', 'Iva']);
    expect(splitPhrases('Mama · Tata ★ Baka ♥ Deka'), ['Mama', 'Tata', 'Baka ♥ Deka']);
    expect(splitPhrases('#love #family #summer'), ['love', 'family', 'summer']);
    expect(splitPhrases('1. Paris\n2. Rome\n- Tokyo\n* Belgrade'), ['Paris', 'Rome', 'Tokyo', 'Belgrade']);
  });

  test('keeps phrases that only look like lists', () {
    expect(splitPhrases('CORRINA, CORRINA'), ['CORRINA, CORRINA']);
    expect(splitPhrases('I love you, baby, forever'), ['I love you, baby, forever']);
    expect(splitPhrases('love — forever'), ['love — forever']);
    expect(splitPhrases('AC/DC\n24/7\nrock / pop / jazz'), ['AC/DC', '24/7', 'rock', 'pop', 'jazz']);
    expect(splitPhrases('Anna, Marko, Jelena, Nikola, Teta Mira'),
        ['Anna', 'Marko', 'Jelena', 'Nikola', 'Teta Mira']);
  });

  test('parseTextPhrases de-dupes across split pieces', () {
    expect(parseTextPhrases('Raat Bhar • Biba • Raat Bhar\nbiba'), ['Raat Bhar', 'Biba']);
    expect(parseTextPhrases('a • b', uppercase: true), ['A', 'B']);
  });
}
