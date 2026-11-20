import 'package:flutter_test/flutter_test.dart';
import 'package:nb_books_mobile/features/read_on_pc/mando_screen.dart';

void main() {
  test('una cita que corta una palabra termina en puntos suspensivos', () {
    expect(
      fraseLegible(
        'Cuando el carro se detuvo, el cochero baj',
        despues: 'ó de',
      ),
      'Cuando el carro se detuvo, el cochero…',
    );
  });

  test('una cita que acaba en una palabra entera se deja como está', () {
    expect(
      fraseLegible('Cuando el carro se detuvo,', despues: ' el cochero'),
      'Cuando el carro se detuvo,',
    );
  });

  test('al empezar un capítulo el título no sale dos veces', () {
    expect(
      fraseLegible('IV IV Diario de Ana  continuado', alEmpezar: true),
      'IV Diario de Ana continuado',
    );
    expect(
      fraseLegible('Libro primero Libro primero Uno', alEmpezar: true),
      'Libro primero Uno',
    );
  });

  test('una palabra repetida a mitad de capítulo no se toca', () {
    expect(fraseLegible('muy muy lejos', despues: '.'), 'muy muy lejos');
  });
}
