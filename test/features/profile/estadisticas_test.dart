import 'package:flutter_test/flutter_test.dart';
import 'package:nb_books_mobile/data/db/database.dart';
import 'package:nb_books_mobile/features/profile/perfil.dart';

Sesion sesion(String id, DateTime inicio, int minutos) => Sesion(
  id: id,
  edicion: 'e',
  inicio: inicio.toUtc().toIso8601String(),
  fin: inicio.add(Duration(minutes: minutos)).toUtc().toIso8601String(),
  desde: '{"href":"c"}',
  pendiente: false,
);

void main() {
  final DateTime hoy = DateTime(2026, 11, 20, 21);

  test('la racha cuenta los días seguidos con lectura hasta hoy', () {
    final Estadisticas e = calcularEstadisticas(
      ediciones: const <Edicion>[],
      posiciones: const <Posicion>[],
      anotaciones: const <Anotacion>[],
      sesiones: <Sesion>[
        sesion('1', hoy, 20),
        sesion('2', hoy.subtract(const Duration(days: 1)), 10),
        sesion('3', hoy.subtract(const Duration(days: 2)), 5),
        sesion('4', hoy.subtract(const Duration(days: 4)), 30),
      ],
      ahora: hoy,
    );
    expect(e.racha, 3);
    expect(e.minutos, 65);
    expect(e.diasSemana.last, 20);
    expect(e.minutosSemana, 65);
  });

  test('si hoy aún no se leyó, la racha sigue viva desde ayer', () {
    final Estadisticas e = calcularEstadisticas(
      ediciones: const <Edicion>[],
      posiciones: const <Posicion>[],
      anotaciones: const <Anotacion>[],
      sesiones: <Sesion>[
        sesion('1', hoy.subtract(const Duration(days: 1)), 10),
      ],
      ahora: hoy,
    );
    expect(e.racha, 1);
  });

  test('una sesión olvidada abierta no cuenta como horas de lectura', () {
    final Estadisticas e = calcularEstadisticas(
      ediciones: const <Edicion>[],
      posiciones: const <Posicion>[],
      anotaciones: const <Anotacion>[],
      sesiones: <Sesion>[sesion('1', hoy, 600)],
      ahora: hoy,
    );
    expect(e.minutos, 180);
  });

  test('unas páginas de menos de un minuto cuentan para la racha', () {
    final Estadisticas e = calcularEstadisticas(
      ediciones: const <Edicion>[],
      posiciones: const <Posicion>[],
      anotaciones: const <Anotacion>[],
      sesiones: <Sesion>[
        Sesion(
          id: '1',
          edicion: 'e',
          inicio: hoy.toUtc().toIso8601String(),
          fin: hoy.add(const Duration(seconds: 40)).toUtc().toIso8601String(),
          desde: '{"href":"c"}',
          pendiente: false,
        ),
      ],
      ahora: hoy,
    );
    expect(e.racha, 1);
  });

  test('el tiempo se enseña en minutos y horas', () {
    expect(duracionLegible(45), '45 min');
    expect(duracionLegible(120), '2 h');
    expect(duracionLegible(200), '3 h 20 min');
  });
}
