import 'package:drift/drift.dart';

// El esquema del teléfono. Cada tabla dice de quién es el dato y en qué sentido
// viaja (ADR-002): lo que es del PC llega por el manifiesto y no se edita aquí;
// lo que se suma lleva `pendiente` hasta que el PC lo confirma.
//
// Ninguna posición es un entero: todas son un Locator en JSON, y la base lo
// comprueba con `json_valid` y la presencia de `href` (regla 3 de AGENTS.md).

/// Comprobación de que una columna guarda un Locator y no otra cosa.
///
/// Con `IS` y no `=`: si el JSON no tiene `href`, `json_type` da NULL, y un
/// CHECK que da NULL deja pasar la fila.
String _locator(String columna) =>
    "json_valid($columna) AND json_type($columna, '\$.href') IS 'text'";

/// Un libro: del catálogo del PC o del teléfono (`origen`).
@DataClassName('Edicion')
class Ediciones extends Table {
  TextColumn get id => text()();
  TextColumn get titulo => text()();
  TextColumn get subtitulo => text().nullable()();

  /// Lista de nombres en JSON.
  TextColumn get autores => text().withDefault(const Constant('[]'))();
  TextColumn get ordenAutor => text().nullable()();
  TextColumn get serie => text().nullable()();
  RealColumn get indiceSerie => real().nullable()();
  TextColumn get idioma => text().nullable()();
  TextColumn get editorial => text().nullable()();
  TextColumn get fecha => text().nullable()();
  TextColumn get sinopsis => text().nullable()();

  /// Lista de `{id, nombre}` en JSON.
  TextColumn get materias => text().withDefault(const Constant('[]'))();
  BoolColumn get portada => boolean().withDefault(const Constant(false))();

  /// `sha256:...`, como en el PC: dice que dos archivos son el mismo libro.
  TextColumn get huella => text().nullable()();
  IntColumn get bytes => integer().withDefault(const Constant(0))();
  TextColumn get tipo => text()();

  /// `pc` o `telefono`. Lo del teléfono nunca sube al PC.
  TextColumn get origen => text().withDefault(const Constant('pc'))();

  /// Ruta del archivo en el teléfono, si está descargado o importado.
  TextColumn get ruta => text().nullable()();

  /// Ruta de la portada en el teléfono, si se descargó.
  TextColumn get rutaPortada => text().nullable()();
  TextColumn get anadidaEn => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    "CHECK (origen IN ('pc', 'telefono'))",
  ];
}

/// Las colecciones del PC, con sus ediciones en JSON. Solo lectura aquí.
@DataClassName('Coleccion')
class Colecciones extends Table {
  TextColumn get id => text()();
  TextColumn get nombre => text()();
  TextColumn get tipo => text()();
  TextColumn get ediciones => text().withDefault(const Constant('[]'))();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// Anotaciones, marcadores y trazos. Inmutables: editar es una nueva que
/// sustituye a la anterior, igual que en el PC.
@DataClassName('Anotacion')
class Anotaciones extends Table {
  TextColumn get id => text()();
  TextColumn get edicion => text()();

  /// `highlight`, `underline`, `note`, `bookmark` o `ink`.
  TextColumn get tipo => text()();
  TextColumn get texto => text().nullable()();
  TextColumn get locator => text()();
  TextColumn get trazo => text().nullable()();
  TextColumn get creadaEn => text()();
  TextColumn get bajaEn => text().nullable()();
  TextColumn get sustituyeA => text().nullable()();

  /// Hecha aquí y todavía sin confirmar por el PC.
  BoolColumn get pendiente => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'CHECK (${_locator('locator')})',
  ];
}

/// Dónde va cada dispositivo en cada libro. `dispositivo` es `telefono` para
/// este y `pc` para el que llega del manifiesto: ninguna pisa a la otra.
@DataClassName('Posicion')
class Posiciones extends Table {
  TextColumn get edicion => text()();
  TextColumn get dispositivo => text()();
  TextColumn get locator => text()();
  RealColumn get progresion => real().nullable()();
  TextColumn get actualizadoEn => text()();
  BoolColumn get pendiente => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{edicion, dispositivo};

  @override
  List<String> get customConstraints => <String>[
    'CHECK (${_locator('locator')})',
    "CHECK (dispositivo IN ('telefono', 'pc'))",
  ];
}

/// Sesiones de lectura: cuándo y de dónde a dónde.
@DataClassName('Sesion')
class Sesiones extends Table {
  TextColumn get id => text()();
  TextColumn get edicion => text()();
  TextColumn get inicio => text()();
  TextColumn get fin => text().nullable()();
  TextColumn get desde => text()();
  TextColumn get hasta => text().nullable()();
  BoolColumn get pendiente => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'CHECK (${_locator('desde')})',
    'CHECK (hasta IS NULL OR ${_locator('hasta')})',
  ];
}

/// Palabras guardadas al consultar.
@DataClassName('Palabra')
class Vocabulario extends Table {
  TextColumn get id => text()();
  TextColumn get edicion => text()();
  TextColumn get lema => text()();
  TextColumn get termino => text()();
  TextColumn get proveedor => text()();
  TextColumn get locator => text()();
  TextColumn get creadaEn => text()();
  BoolColumn get pendiente => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'CHECK (${_locator('locator')})',
  ];
}

/// Tarjetas de estudio: las genera el PC. Su programación se calcula aquí con
/// el mismo motor, reproduciendo los repasos sobre la base.
@DataClassName('Tarjeta')
class Tarjetas extends Table {
  TextColumn get id => text()();
  TextColumn get edicion => text().nullable()();
  TextColumn get tipo => text()();
  TextColumn get anverso => text()();
  TextColumn get reverso => text()();
  TextColumn get opciones => text().nullable()();

  /// La base de la programación, en JSON, tal como la manda el PC.
  TextColumn get base => text()();
  IntColumn get repeticiones => integer().withDefault(const Constant(0))();
  IntColumn get intervaloDias => integer().withDefault(const Constant(0))();
  RealColumn get facilidad => real().withDefault(const Constant(2.5))();
  TextColumn get venceEn => text()();
  TextColumn get repasadaEn => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// Cada repaso, de cualquiera de los dos lados. Se suman y nunca se editan.
@DataClassName('Repaso')
class Repasos extends Table {
  TextColumn get id => text()();
  TextColumn get tarjeta => text()();
  TextColumn get calificacion => text()();
  TextColumn get repasadoEn => text()();
  BoolColumn get pendiente => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    "CHECK (calificacion IN ('again', 'hard', 'good', 'easy'))",
  ];
}

/// Notas de Estudio. Son del PC; editarlas aquí sube el cambio con la revisión
/// que se vio, y si el PC cambió entre tanto la edición llega como nota nueva.
@DataClassName('Nota')
class Notas extends Table {
  TextColumn get id => text()();
  TextColumn get titulo => text()();
  TextColumn get cuerpo => text()();
  IntColumn get revision => integer().withDefault(const Constant(0))();
  TextColumn get actualizadaEn => text()();
  BoolColumn get pendiente => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// Preferencias y estado de la sincronización, como pares clave y valor.
@DataClassName('Ajuste')
class Ajustes extends Table {
  TextColumn get clave => text()();
  TextColumn get valor => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{clave};
}
