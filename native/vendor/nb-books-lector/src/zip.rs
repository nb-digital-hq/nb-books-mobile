//! Lector de contenedores ZIP: de solo lectura y deliberadamente estricto.
//!
//! EPUB y cómic son ZIP, así que este módulo es la frontera por la que entra el
//! contenido de archivos que el usuario no escribió y que pueden estar hechos
//! para hacer daño. Sus reglas están escritas desde esa suposición.
//!
//! # Por qué es propio y no una biblioteca
//!
//! Los límites contra bombas de descompresión que exige la. son
//! el núcleo de la defensa, y aquí viven **dentro** del lector: no hay forma de
//! leer una entrada saltándoselos. Envolviendo una biblioteca ajena habría que
//! acordarse de aplicarlos en cada uso, y la primera vez que alguien olvide
//! hacerlo no lo notará nadie hasta que un archivo de 4 KB se convierta en
//! cuarenta gigabytes de memoria.
//!
//! El precio es que hay que ser estricto: **todo lo que no se entiende se
//! rechaza**. No hay ZIP64, ni cifrado, ni métodos de compresión más allá de los
//! dos que usan estos formatos, ni entradas cuyo tamaño no esté en el índice. Un
//! EPUB que necesite algo de eso no es un EPUB que queramos abrir a ciegas.
//!
//! Contrato: `docs/audit/threat-model.md`.

use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use crate::error::{NbError, NbResult};
use crate::security::validate_archive_entry;

/// Máximo de entradas de un contenedor.
///
/// Un cómic largo no pasa de unos cientos de páginas y un EPUB, de unos miles de
/// recursos. Un contenedor con cien mil entradas no es un libro: es un intento
/// de agotar la memoria solo con el índice.
const MAX_ENTRADAS: usize = 20_000;

/// Máximo que puede ocupar una entrada al descomprimirse.
const MAX_ENTRADA: u64 = 64 * 1024 * 1024;

/// Máximo que puede ocupar el contenedor entero al descomprimirse.
const MAX_TOTAL: u64 = 512 * 1024 * 1024;

/// Ratio de compresión por encima del cual se rechaza la entrada.
///
/// El texto comprime bien, pero no tanto: un XHTML normal ronda 5:1 y uno muy
/// repetitivo puede llegar a 50:1. Un archivo de ceros llega a 1000:1, y eso ya
/// no es un libro.
const MAX_RATIO: u64 = 150;

/// Longitud máxima del comentario final, que fija la ley del formato.
const MAX_COMENTARIO: usize = 65_535;

const FIRMA_FIN: [u8; 4] = [0x50, 0x4b, 0x05, 0x06];
const FIRMA_CENTRAL: [u8; 4] = [0x50, 0x4b, 0x01, 0x02];
const FIRMA_LOCAL: [u8; 4] = [0x50, 0x4b, 0x03, 0x04];

const METODO_ALMACENADO: u16 = 0;
const METODO_DESINFLADO: u16 = 8;

/// Una entrada del contenedor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// Nombre interno, ya validado: nunca escapa del destino.
    pub name: String,
    pub compressed_size: u64,
    pub uncompressed_size: u64,
    method: u16,
    local_header_offset: u64,
}

/// Un contenedor ZIP abierto.
///
/// No carga el contenido: guarda el índice y lee cada entrada cuando se pide.
/// Un cómic de trescientas páginas no cabe en memoria y no hace falta que quepa.
pub struct Archive {
    archivo: std::fs::File,
    entries: Vec<Entry>,
}

impl Archive {
    /// Abre un contenedor y lee su índice.
    ///
    /// # Errors
    ///
    /// - [`NbError::FileNotFound`] si la ruta no existe.
    /// - [`NbError::DocumentCorrupted`] si no es un ZIP legible, si usa algo que
    ///   este lector no admite, o si alguna entrada supera los límites.
    /// - [`NbError::PathNotAllowed`] si alguna entrada intenta escapar del
    ///   destino con `../` o con una ruta absoluta.
    /// - [`NbError::StorageFailure`] si la lectura falla.
    pub fn open(path: &Path) -> NbResult<Self> {
        let mut archivo = crate::paths::open_noatime(path).map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                NbError::FileNotFound
            } else {
                NbError::StorageFailure
            }
        })?;

        let entries = leer_indice(&mut archivo)?;
        Ok(Self { archivo, entries })
    }

    /// Índice del contenedor.
    #[must_use]
    pub fn entries(&self) -> &[Entry] {
        &self.entries
    }

    /// Indica si existe una entrada con ese nombre.
    #[must_use]
    pub fn contains(&self, name: &str) -> bool {
        self.entries.iter().any(|e| e.name == name)
    }

    /// Lee una entrada completa.
    ///
    /// # Errors
    ///
    /// - [`NbError::FileNotFound`] si no hay ninguna entrada con ese nombre.
    /// - [`NbError::DocumentCorrupted`] si la entrada no se puede descomprimir o
    ///   si al hacerlo supera lo que su propio índice declaraba.
    /// - [`NbError::StorageFailure`] si la lectura falla.
    pub fn read(&mut self, name: &str) -> NbResult<Vec<u8>> {
        let entrada = self
            .entries
            .iter()
            .find(|e| e.name == name)
            .ok_or(NbError::FileNotFound)?
            .clone();

        // La cabecera local repite el nombre y los extras, y su longitud puede
        // no coincidir con la del directorio central. Hay que leerla para saber
        // dónde empiezan los datos de verdad.
        self.archivo
            .seek(SeekFrom::Start(entrada.local_header_offset))
            .map_err(|_| NbError::DocumentCorrupted)?;

        let mut cabecera = [0_u8; 30];
        self.archivo
            .read_exact(&mut cabecera)
            .map_err(|_| NbError::DocumentCorrupted)?;

        if cabecera[..4] != FIRMA_LOCAL {
            return Err(NbError::DocumentCorrupted);
        }

        let len_nombre = u16::from_le_bytes([cabecera[26], cabecera[27]]) as u64;
        let len_extra = u16::from_le_bytes([cabecera[28], cabecera[29]]) as u64;

        self.archivo
            .seek(SeekFrom::Current(
                i64::try_from(len_nombre + len_extra).map_err(|_| NbError::DocumentCorrupted)?,
            ))
            .map_err(|_| NbError::DocumentCorrupted)?;

        let mut comprimido = vec![0_u8; usize::try_from(entrada.compressed_size).unwrap_or(0)];
        self.archivo
            .read_exact(&mut comprimido)
            .map_err(|_| NbError::DocumentCorrupted)?;

        let descomprimido = match entrada.method {
            METODO_ALMACENADO => comprimido,
            METODO_DESINFLADO => desinflar(&comprimido, entrada.uncompressed_size)?,
            // El índice ya lo rechazó; llegar aquí sería un fallo del propio
            // lector, no del archivo.
            _ => return Err(NbError::DocumentCorrupted),
        };

        // Lo que declaraba el índice y lo que ha salido tienen que coincidir. Un
        // archivo que declara mil bytes y produce un gigabyte es exactamente la
        // bomba que los límites existen para parar.
        if descomprimido.len() as u64 != entrada.uncompressed_size {
            tracing::warn!("una entrada no produjo el tamaño que declaraba");
            return Err(NbError::DocumentCorrupted);
        }

        Ok(descomprimido)
    }

    /// Lee una entrada y la interpreta como texto UTF-8.
    ///
    /// # Errors
    ///
    /// Los de [`Self::read`], y [`NbError::DocumentCorrupted`] si no es UTF-8
    /// válido.
    pub fn read_text(&mut self, name: &str) -> NbResult<String> {
        let bytes = self.read(name)?;
        String::from_utf8(bytes).map_err(|_| {
            tracing::warn!("una entrada del contenedor no es UTF-8");
            NbError::DocumentCorrupted
        })
    }
}

/// Descomprime con un tope: el descompresor se detiene al alcanzarlo, en lugar
/// de reservar memoria mientras el archivo se lo pida.
fn desinflar(comprimido: &[u8], esperado: u64) -> NbResult<Vec<u8>> {
    use flate2::read::DeflateDecoder;

    let mut salida = Vec::with_capacity(usize::try_from(esperado.min(MAX_ENTRADA)).unwrap_or(0));
    // `take` es lo que convierte el tope en una garantía y no en una
    // comprobación posterior: nunca se materializa más de lo permitido.
    DeflateDecoder::new(comprimido)
        .take(MAX_ENTRADA + 1)
        .read_to_end(&mut salida)
        .map_err(|_| NbError::DocumentCorrupted)?;

    if salida.len() as u64 > MAX_ENTRADA {
        tracing::warn!("una entrada supera el tamaño máximo al descomprimirse");
        return Err(NbError::DocumentCorrupted);
    }

    Ok(salida)
}

/// Lee el directorio central y construye el índice.
fn leer_indice(archivo: &mut std::fs::File) -> NbResult<Vec<Entry>> {
    let tamano = archivo
        .metadata()
        .map_err(|_| NbError::StorageFailure)?
        .len();

    let (entradas_declaradas, offset_central) = localizar_fin(archivo, tamano)?;

    if entradas_declaradas > MAX_ENTRADAS {
        tracing::warn!(
            entradas = entradas_declaradas,
            "contenedor con demasiadas entradas"
        );
        return Err(NbError::DocumentCorrupted);
    }

    archivo
        .seek(SeekFrom::Start(offset_central))
        .map_err(|_| NbError::DocumentCorrupted)?;

    let mut central = Vec::new();
    archivo
        .take(tamano - offset_central)
        .read_to_end(&mut central)
        .map_err(|_| NbError::StorageFailure)?;

    let mut entradas = Vec::with_capacity(entradas_declaradas);
    let mut total_descomprimido: u64 = 0;
    let mut i = 0_usize;

    // Se recorren los registros declarados, **no** las entradas que se guardan.
    // No es lo mismo: los directorios cuentan como registro y no se guardan,
    // así que contar los guardados hace que el recorrido se pase del final del
    // directorio central y el contenedor entero parezca corrupto. Los archivos
    // de prueba no tenían entradas de directorio y el corpus real sí: 71 de cada
    // 250 EPUB reales se rechazaban por esto.
    for _ in 0..entradas_declaradas {
        if i + 46 > central.len() || central[i..i + 4] != FIRMA_CENTRAL {
            return Err(NbError::DocumentCorrupted);
        }

        let campo16 = |d: usize| u16::from_le_bytes([central[i + d], central[i + d + 1]]);
        let campo32 = |d: usize| {
            u32::from_le_bytes([
                central[i + d],
                central[i + d + 1],
                central[i + d + 2],
                central[i + d + 3],
            ])
        };

        let banderas = campo16(8);
        let metodo = campo16(10);
        let comprimido = u64::from(campo32(20));
        let descomprimido = u64::from(campo32(24));
        let len_nombre = campo16(28) as usize;
        let len_extra = campo16(30) as usize;
        let len_comentario = campo16(32) as usize;
        let offset_local = u64::from(campo32(42));

        // El bit 0 marca cifrado. Un contenedor cifrado no se abre a medias: no
        // se abre.
        if banderas & 0x0001 != 0 {
            tracing::warn!("contenedor con entradas cifradas");
            return Err(NbError::DocumentCorrupted);
        }
        // El bit 3 marca descriptor de datos: los tamaños van **detrás** de los
        // datos. Lo que no se admite no es el bit, es no saber el tamaño antes de
        // leer; y este lector se guía por el directorio central, que es donde el
        // formato exige que los tamaños estén de verdad. Un escritor en flujo
        // —`miniz`, y con él PyTorch, que es cómo viene un `.pt`— deja el bit
        // puesto y el tamaño escrito, y rechazarlo era rechazar un archivo
        // perfectamente acotado. Sin tamaño declarado sí se rechaza, que es el
        // caso que el límite existe para parar.
        if banderas & 0x0008 != 0 && (comprimido == 0 || descomprimido == 0) {
            tracing::warn!("contenedor con entradas sin tamaño en el índice");
            return Err(NbError::DocumentCorrupted);
        }
        if metodo != METODO_ALMACENADO && metodo != METODO_DESINFLADO {
            tracing::warn!(metodo, "método de compresión no admitido");
            return Err(NbError::DocumentCorrupted);
        }
        // Los centinelas de ZIP64. Este lector no lo admite: los formatos que
        // nos interesan no lo necesitan, y admitirlo a medias es peor que no
        // admitirlo.
        if comprimido == u64::from(u32::MAX) || descomprimido == u64::from(u32::MAX) {
            tracing::warn!("contenedor en formato ZIP64");
            return Err(NbError::DocumentCorrupted);
        }

        let inicio_nombre = i + 46;
        let fin_nombre = inicio_nombre + len_nombre;
        if fin_nombre > central.len() {
            return Err(NbError::DocumentCorrupted);
        }
        let nombre = String::from_utf8_lossy(&central[inicio_nombre..fin_nombre]).into_owned();

        // Una entrada que termina en `/` es un directorio: no tiene contenido y
        // no se valida como ruta de archivo.
        if !nombre.ends_with('/') {
            // La misma validación que usan las pruebas de caos.
            validate_archive_entry(&nombre)?;

            if descomprimido > MAX_ENTRADA {
                tracing::warn!("una entrada declara un tamaño excesivo");
                return Err(NbError::DocumentCorrupted);
            }
            // El ratio se mira antes de descomprimir nada: es el único momento
            // en que parar sale gratis.
            if comprimido > 0 && descomprimido / comprimido.max(1) > MAX_RATIO {
                tracing::warn!("una entrada tiene un ratio de compresión desmedido");
                return Err(NbError::DocumentCorrupted);
            }

            total_descomprimido = total_descomprimido.saturating_add(descomprimido);
            if total_descomprimido > MAX_TOTAL {
                tracing::warn!("el contenedor supera el tamaño total admitido");
                return Err(NbError::DocumentCorrupted);
            }

            entradas.push(Entry {
                name: nombre,
                compressed_size: comprimido,
                uncompressed_size: descomprimido,
                method: metodo,
                local_header_offset: offset_local,
            });
        }

        i = fin_nombre + len_extra + len_comentario;
    }

    Ok(entradas)
}

/// Localiza el registro de fin del directorio central.
///
/// Va al final del archivo, después de un comentario de longitud arbitraria, así
/// que hay que buscarlo hacia atrás. La ley del formato acota ese comentario a
/// 65 535 bytes, y ese es el único tramo que se lee.
fn localizar_fin(archivo: &mut std::fs::File, tamano: u64) -> NbResult<(usize, u64)> {
    let ventana = (MAX_COMENTARIO + 22).min(usize::try_from(tamano).unwrap_or(usize::MAX));
    let desde = tamano.saturating_sub(ventana as u64);

    archivo
        .seek(SeekFrom::Start(desde))
        .map_err(|_| NbError::DocumentCorrupted)?;
    let mut cola = Vec::with_capacity(ventana);
    archivo
        .read_to_end(&mut cola)
        .map_err(|_| NbError::StorageFailure)?;

    let posicion = cola
        .windows(4)
        .rposition(|v| v == FIRMA_FIN)
        .ok_or(NbError::DocumentCorrupted)?;

    if posicion + 22 > cola.len() {
        return Err(NbError::DocumentCorrupted);
    }
    let fin = &cola[posicion..];

    let entradas = u16::from_le_bytes([fin[10], fin[11]]) as usize;
    let offset_central = u64::from(u32::from_le_bytes([fin[16], fin[17], fin[18], fin[19]]));

    // Centinelas de ZIP64 también aquí.
    if entradas == usize::from(u16::MAX) || offset_central == u64::from(u32::MAX) {
        tracing::warn!("contenedor en formato ZIP64");
        return Err(NbError::DocumentCorrupted);
    }
    if offset_central >= tamano {
        return Err(NbError::DocumentCorrupted);
    }

    Ok((entradas, offset_central))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(nombre: &str) -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../tests/fixtures")
            .join(nombre)
    }

    #[test]
    fn lee_el_indice_de_un_epub_valido() {
        let archivo = Archive::open(&fixture("minimo-valido.epub")).expect("contenedor");

        let nombres: Vec<&str> = archivo.entries().iter().map(|e| e.name.as_str()).collect();
        assert_eq!(
            nombres,
            vec![
                "mimetype",
                "META-INF/container.xml",
                "OEBPS/content.opf",
                "OEBPS/capitulo1.xhtml"
            ]
        );
        assert!(archivo.contains("OEBPS/content.opf"));
        assert!(!archivo.contains("no-existe.xhtml"));
    }

    /// Los dos métodos que usan estos formatos: `mimetype` va sin comprimir por
    /// exigencia del propio EPUB, y el resto desinflado.
    #[test]
    fn lee_entradas_almacenadas_y_desinfladas() {
        let mut archivo = Archive::open(&fixture("minimo-valido.epub")).expect("contenedor");

        assert_eq!(
            archivo.read_text("mimetype").expect("almacenada"),
            "application/epub+zip"
        );
        let opf = archivo.read_text("OEBPS/content.opf").expect("desinflada");
        assert!(opf.contains("<dc:title>Documento de prueba de NB Books</dc:title>"));
    }

    #[test]
    fn una_entrada_que_no_existe_se_distingue_de_un_contenedor_roto() {
        let mut archivo = Archive::open(&fixture("minimo-valido.epub")).expect("contenedor");
        assert_eq!(archivo.read("no-existe.xhtml"), Err(NbError::FileNotFound));
    }

    /// **La defensa que este lector existe para tener.** El corpus trae un
    /// contenedor con entradas `../../` y `..\\..\\`, y el índice se rechaza
    /// entero: no se abre a medias para leer las entradas buenas.
    #[test]
    fn un_contenedor_con_rutas_de_escape_se_rechaza_entero() {
        assert_eq!(
            Archive::open(&fixture("recorrido-directorios.cbz")).err(),
            Some(NbError::PathNotAllowed)
        );
    }

    #[test]
    fn un_archivo_que_no_es_zip_se_rechaza() {
        assert_eq!(
            Archive::open(&fixture("minimo-valido.pdf")).err(),
            Some(NbError::DocumentCorrupted)
        );
    }

    #[test]
    fn un_archivo_inexistente_se_distingue_de_uno_roto() {
        let ruta = crate::paths::temporal_de_pruebas()
            .join(format!("nb-zip-no-existe-{}", std::process::id()));
        assert_eq!(Archive::open(&ruta).err(), Some(NbError::FileNotFound));
    }

    // --- Bombas de descompresión --------------------------------------------

    /// Construye un ZIP a mano con una entrada que miente sobre su tamaño.
    ///
    /// Se fabrica en la prueba y no en el corpus porque un archivo de cuarenta
    /// gigabytes descomprimidos no cabe en un repositorio, que es justamente lo
    /// que hace peligrosas a estas bombas.
    fn zip_con_entrada(
        nombre: &str,
        datos_comprimidos: &[u8],
        metodo: u16,
        declarado_descomprimido: u32,
    ) -> Vec<u8> {
        zip_con_banderas(
            nombre,
            datos_comprimidos,
            metodo,
            declarado_descomprimido,
            0,
            true,
        )
    }

    /// Como [`zip_con_entrada`], eligiendo las banderas y si el índice declara
    /// los tamaños. Es lo que distingue a un escritor en flujo de uno que
    /// esconde el tamaño hasta después de los datos.
    fn zip_con_banderas(
        nombre: &str,
        datos_comprimidos: &[u8],
        metodo: u16,
        declarado_descomprimido: u32,
        banderas: u16,
        declarar_tamanos: bool,
    ) -> Vec<u8> {
        let mut salida = Vec::new();
        let nombre_bytes = nombre.as_bytes();
        let comprimido = u32::try_from(datos_comprimidos.len()).expect("cabe");

        // Cabecera local.
        let (central_comprimido, central_descomprimido) = if declarar_tamanos {
            (comprimido, declarado_descomprimido)
        } else {
            (0, 0)
        };

        salida.extend_from_slice(&FIRMA_LOCAL);
        salida.extend_from_slice(&[20, 0]); // versión
        salida.extend_from_slice(&banderas.to_le_bytes());
        salida.extend_from_slice(&metodo.to_le_bytes());
        salida.extend_from_slice(&[0; 8]); // hora, fecha, crc
        salida.extend_from_slice(&comprimido.to_le_bytes());
        salida.extend_from_slice(&declarado_descomprimido.to_le_bytes());
        salida.extend_from_slice(
            &u16::try_from(nombre_bytes.len())
                .expect("cabe")
                .to_le_bytes(),
        );
        salida.extend_from_slice(&[0, 0]); // extra
        salida.extend_from_slice(nombre_bytes);
        salida.extend_from_slice(datos_comprimidos);

        // Directorio central.
        let offset_central = u32::try_from(salida.len()).expect("cabe");
        salida.extend_from_slice(&FIRMA_CENTRAL);
        salida.extend_from_slice(&[20, 0, 20, 0]); // versiones
        salida.extend_from_slice(&banderas.to_le_bytes());
        salida.extend_from_slice(&metodo.to_le_bytes());
        salida.extend_from_slice(&[0; 8]);
        salida.extend_from_slice(&central_comprimido.to_le_bytes());
        salida.extend_from_slice(&central_descomprimido.to_le_bytes());
        salida.extend_from_slice(
            &u16::try_from(nombre_bytes.len())
                .expect("cabe")
                .to_le_bytes(),
        );
        // extra (2), comentario (2), disco (2), atributos internos (2),
        // atributos externos (4). Doce bytes exactos: uno de más desplaza el
        // nombre y el índice deja de encontrar la entrada.
        salida.extend_from_slice(&[0; 12]);
        salida.extend_from_slice(&0_u32.to_le_bytes()); // offset local
        salida.extend_from_slice(nombre_bytes);

        let tamano_central = u32::try_from(salida.len()).expect("cabe") - offset_central;

        // Fin del directorio central.
        salida.extend_from_slice(&FIRMA_FIN);
        salida.extend_from_slice(&[0; 4]); // discos
        salida.extend_from_slice(&1_u16.to_le_bytes());
        salida.extend_from_slice(&1_u16.to_le_bytes());
        salida.extend_from_slice(&tamano_central.to_le_bytes());
        salida.extend_from_slice(&offset_central.to_le_bytes());
        salida.extend_from_slice(&[0, 0]); // comentario
        salida
    }

    fn escribir_temporal(nombre: &str, contenido: &[u8]) -> std::path::PathBuf {
        let dir =
            crate::paths::temporal_de_pruebas().join(format!("nb-zip-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("directorio");
        let ruta = dir.join(nombre);
        std::fs::write(&ruta, contenido).expect("archivo");
        ruta
    }

    /// Una entrada que declara un ratio desmedido se rechaza **antes** de
    /// descomprimir nada. Es el único momento en que parar sale gratis.
    #[test]
    fn una_entrada_con_ratio_desmedido_se_rechaza_sin_descomprimirla() {
        use flate2::write::DeflateEncoder;
        use std::io::Write;

        // Un megabyte de ceros comprime a poco más de mil bytes: ratio de mil a
        // uno, muy por encima del límite.
        let mut codificador = DeflateEncoder::new(Vec::new(), flate2::Compression::best());
        codificador
            .write_all(&vec![0_u8; 1024 * 1024])
            .expect("comprime");
        let comprimido = codificador.finish().expect("comprime");

        let bomba = zip_con_entrada("bomba.txt", &comprimido, METODO_DESINFLADO, 1024 * 1024);
        let ruta = escribir_temporal("bomba-ratio.zip", &bomba);

        assert_eq!(
            Archive::open(&ruta).err(),
            Some(NbError::DocumentCorrupted),
            "una bomba de compresión no puede llegar a abrirse"
        );
        let _ = std::fs::remove_file(ruta);
    }

    /// Una entrada que declara más de lo permitido tampoco se abre, aunque su
    /// ratio sea razonable.
    #[test]
    fn una_entrada_demasiado_grande_se_rechaza() {
        let enorme = zip_con_entrada("enorme.bin", &[0; 1000], METODO_ALMACENADO, u32::MAX - 1);
        let ruta = escribir_temporal("enorme.zip", &enorme);

        assert_eq!(Archive::open(&ruta).err(), Some(NbError::DocumentCorrupted));
        let _ = std::fs::remove_file(ruta);
    }

    /// Lo que el índice declara y lo que sale al descomprimir tienen que
    /// coincidir. Un archivo que dice mil bytes y produce otra cosa está
    /// mintiendo, y da igual en qué dirección.
    #[test]
    fn una_entrada_que_no_produce_lo_que_declara_se_rechaza() {
        let mentirosa = zip_con_entrada("mentira.txt", b"hola", METODO_ALMACENADO, 4000);
        let ruta = escribir_temporal("mentira.zip", &mentirosa);

        // 4000 / 4 = 1000, por encima del ratio: ni siquiera abre.
        assert_eq!(Archive::open(&ruta).err(), Some(NbError::DocumentCorrupted));

        // Con un tamaño creíble, el índice pasa y falla al leer.
        let sutil = zip_con_entrada("sutil.txt", b"hola", METODO_ALMACENADO, 8);
        let ruta_sutil = escribir_temporal("sutil.zip", &sutil);
        let mut archivo = Archive::open(&ruta_sutil).expect("índice creíble");
        assert_eq!(archivo.read("sutil.txt"), Err(NbError::DocumentCorrupted));

        let _ = std::fs::remove_file(ruta);
        let _ = std::fs::remove_file(ruta_sutil);
    }

    /// Regresión del defecto que encontró el corpus real.
    ///
    /// El recorrido del directorio central contaba las entradas **guardadas** en
    /// lugar de los registros **declarados**. Un directorio cuenta como registro
    /// y no se guarda, así que en cuanto un contenedor traía uno, el recorrido
    /// se pasaba del final y el archivo entero parecía corrupto. Los archivos de
    /// prueba fabricados no tenían entradas de directorio; el corpus real sí, y
    /// **71 de cada 250 EPUB reales se rechazaban por esto**.
    #[test]
    fn un_contenedor_con_entradas_de_directorio_se_abre() {
        let mut salida = Vec::new();
        let mut central = Vec::new();

        // Primero el directorio, después el archivo: es el orden habitual.
        for (nombre, datos) in [("OEBPS/", &b""[..]), ("OEBPS/libro.txt", &b"contenido"[..])] {
            let offset = u32::try_from(salida.len()).expect("cabe");
            let nb = nombre.as_bytes();
            let largo = u32::try_from(datos.len()).expect("cabe");

            salida.extend_from_slice(&FIRMA_LOCAL);
            salida.extend_from_slice(&[20, 0, 0, 0, 0, 0]);
            salida.extend_from_slice(&[0; 8]);
            salida.extend_from_slice(&largo.to_le_bytes());
            salida.extend_from_slice(&largo.to_le_bytes());
            salida.extend_from_slice(&u16::try_from(nb.len()).expect("cabe").to_le_bytes());
            salida.extend_from_slice(&[0, 0]);
            salida.extend_from_slice(nb);
            salida.extend_from_slice(datos);

            central.extend_from_slice(&FIRMA_CENTRAL);
            central.extend_from_slice(&[20, 0, 20, 0, 0, 0, 0, 0]);
            central.extend_from_slice(&[0; 8]);
            central.extend_from_slice(&largo.to_le_bytes());
            central.extend_from_slice(&largo.to_le_bytes());
            central.extend_from_slice(&u16::try_from(nb.len()).expect("cabe").to_le_bytes());
            central.extend_from_slice(&[0; 12]);
            central.extend_from_slice(&offset.to_le_bytes());
            central.extend_from_slice(nb);
        }

        let offset_central = u32::try_from(salida.len()).expect("cabe");
        let tamano_central = u32::try_from(central.len()).expect("cabe");
        salida.extend_from_slice(&central);
        salida.extend_from_slice(&FIRMA_FIN);
        salida.extend_from_slice(&[0; 4]);
        salida.extend_from_slice(&2_u16.to_le_bytes());
        salida.extend_from_slice(&2_u16.to_le_bytes());
        salida.extend_from_slice(&tamano_central.to_le_bytes());
        salida.extend_from_slice(&offset_central.to_le_bytes());
        salida.extend_from_slice(&[0, 0]);

        let ruta = escribir_temporal("con-directorio.zip", &salida);
        let mut archivo = Archive::open(&ruta).expect("un contenedor con directorios debe abrirse");

        // El directorio no es una entrada legible, pero no impide leer el resto.
        assert_eq!(archivo.entries().len(), 1);
        assert_eq!(
            archivo.read_text("OEBPS/libro.txt").expect("entrada"),
            "contenido"
        );

        let _ = std::fs::remove_file(ruta);
    }

    /// Todo lo que este lector no entiende se rechaza. Un contenedor cifrado no
    /// se abre a medias: no se abre.
    #[test]
    fn lo_que_no_se_entiende_se_rechaza() {
        // Método de compresión desconocido.
        let raro = zip_con_entrada("raro.txt", b"hola", 99, 4);
        let ruta = escribir_temporal("metodo-raro.zip", &raro);
        assert_eq!(Archive::open(&ruta).err(), Some(NbError::DocumentCorrupted));
        let _ = std::fs::remove_file(ruta);

        // Cifrado: bandera 0 activada en el directorio central.
        let mut cifrado = zip_con_entrada("cifrado.txt", b"hola", METODO_ALMACENADO, 4);
        let central = cifrado
            .windows(4)
            .rposition(|v| v == FIRMA_CENTRAL)
            .expect("directorio central");
        cifrado[central + 8] |= 0x01;
        let ruta = escribir_temporal("cifrado.zip", &cifrado);
        assert_eq!(Archive::open(&ruta).err(), Some(NbError::DocumentCorrupted));
        let _ = std::fs::remove_file(ruta);
    }

    /// **Regresión.** Una entrada escrita en flujo —bit 3 puesto— con
    /// su tamaño en el índice se lee.
    ///
    /// Así vienen los pesos de una voz: PyTorch escribe con `miniz`, que deja el
    /// bit del descriptor puesto aunque escriba los tamaños. Rechazarlo era
    /// rechazar un archivo perfectamente acotado, y costó una tarde de
    /// "DocumentCorrupted" sobre un archivo que no tenía nada de corrupto.
    #[test]
    fn una_entrada_en_flujo_con_su_tamano_declarado_se_lee() {
        let datos = b"contenido de una entrada escrita en flujo";
        let zip = zip_con_banderas(
            "datos/0",
            datos,
            METODO_ALMACENADO,
            u32::try_from(datos.len()).expect("cabe"),
            0x0808,
            true,
        );
        let ruta = escribir_temporal("flujo-con-tamano.zip", &zip);
        let mut archivo = Archive::open(&ruta).expect("se abre");
        assert_eq!(archivo.read("datos/0").expect("se lee"), datos);
    }

    /// Y la que **no** declara su tamaño se sigue rechazando: sin tamaño en el
    /// índice no hay forma de acotar antes de leer, que es lo que este lector
    /// existe para poder hacer.
    #[test]
    fn una_entrada_sin_tamano_en_el_indice_se_rechaza() {
        let datos = b"contenido sin tamano declarado";
        let zip = zip_con_banderas(
            "datos/0",
            datos,
            METODO_ALMACENADO,
            u32::try_from(datos.len()).expect("cabe"),
            0x0808,
            false,
        );
        let ruta = escribir_temporal("flujo-sin-tamano.zip", &zip);
        assert_eq!(Archive::open(&ruta).err(), Some(NbError::DocumentCorrupted));
    }
}
