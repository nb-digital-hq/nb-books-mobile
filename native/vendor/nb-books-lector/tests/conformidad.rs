// El corpus de conformidad del motor de lectura.
//
// NB Books y NB Books Mobile tienen que señalar el mismo sitio con el mismo
// Locator: una anotación hecha en un dispositivo cae en el mismo párrafo en el
// otro (ADR-016). Esta prueba genera un EPUB de contenido fijo, le pide al
// motor los Locators, las resoluciones, los fragmentos y el marcado, y los
// compara con `conformidad.json`. El mismo archivo viaja con la exportación al
// teléfono, que repite la prueba contra su copia del motor.
//
// Si un cambio del motor mueve una posición, esta prueba falla. Regrabar con
// `NB_GRABAR=1` es aceptar que las posiciones guardadas se mueven, y eso es un
// cambio de contrato con el teléfono.

use std::io::Write;
use std::path::{Path, PathBuf};

use nb_books_lector::reader::epub::EpubDocument;
use nb_books_lector::reader::{DocumentProvider, NativePosition};
use serde_json::{json, Value};

const CAPITULOS: [(&str, &str); 3] = [
    (
        "c1.xhtml",
        "<h1>Primera parte</h1>\
         <p>La niebla bajaba del monte como un animal cansado.</p>\
         <p>Nadie recordaba quién plantó el <em>primer</em> almendro &amp; nadie preguntaba.</p>\
         <script>no se pinta</script>\
         <p>El reloj marcaba las cuatro desde que se fue el último tren.</p>",
    ),
    (
        "c2.xhtml",
        "<h2>Segunda parte</h2>\
         <ul><li>Uno: «comillas» y acentos áéíóú.</li><li>Dos: ñandú, pingüino.</li></ul>\
         <blockquote><p>Una cita dentro de una cita.</p></blockquote>\
         <p>Escribir un mapa de lo que no existe exige paciencia.</p>",
    ),
    (
        "c3.xhtml",
        "<h2>Tercera parte</h2>\
         <p>Cuando llovía, el río cambiaba de nombre.</p>\
         <p>Cuando llovía, los vecinos cambiaban de humor.</p>",
    ),
];

/// Un ZIP sin comprimir, escrito a mano para que el corpus no dependa de
/// ningún compresor: los bytes son los mismos en cualquier máquina.
fn zip(entradas: &[(&str, Vec<u8>)]) -> Vec<u8> {
    fn crc32(datos: &[u8]) -> u32 {
        let mut crc = 0xffff_ffff_u32;
        for b in datos {
            crc ^= u32::from(*b);
            for _ in 0..8 {
                crc = if crc & 1 == 1 {
                    (crc >> 1) ^ 0xedb8_8320
                } else {
                    crc >> 1
                };
            }
        }
        !crc
    }
    let mut cuerpo = Vec::new();
    let mut central = Vec::new();
    for (nombre, datos) in entradas {
        let desplazamiento = u32::try_from(cuerpo.len()).expect("cabe");
        let crc = crc32(datos);
        let largo = u32::try_from(datos.len()).expect("cabe");
        let n = u16::try_from(nombre.len()).expect("cabe");
        cuerpo.extend_from_slice(&0x0403_4b50_u32.to_le_bytes());
        cuerpo.extend_from_slice(&[20, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        cuerpo.extend_from_slice(&crc.to_le_bytes());
        cuerpo.extend_from_slice(&largo.to_le_bytes());
        cuerpo.extend_from_slice(&largo.to_le_bytes());
        cuerpo.extend_from_slice(&n.to_le_bytes());
        cuerpo.extend_from_slice(&0_u16.to_le_bytes());
        cuerpo.extend_from_slice(nombre.as_bytes());
        cuerpo.extend_from_slice(datos);
        central.extend_from_slice(&0x0201_4b50_u32.to_le_bytes());
        central.extend_from_slice(&[20, 0, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        central.extend_from_slice(&crc.to_le_bytes());
        central.extend_from_slice(&largo.to_le_bytes());
        central.extend_from_slice(&largo.to_le_bytes());
        central.extend_from_slice(&n.to_le_bytes());
        central.extend_from_slice(&[0; 12]);
        central.extend_from_slice(&desplazamiento.to_le_bytes());
        central.extend_from_slice(nombre.as_bytes());
    }
    let inicio = u32::try_from(cuerpo.len()).expect("cabe");
    let largo_central = u32::try_from(central.len()).expect("cabe");
    let cuantas = u16::try_from(entradas.len()).expect("cabe");
    cuerpo.extend_from_slice(&central);
    cuerpo.extend_from_slice(&0x0605_4b50_u32.to_le_bytes());
    cuerpo.extend_from_slice(&[0, 0, 0, 0]);
    cuerpo.extend_from_slice(&cuantas.to_le_bytes());
    cuerpo.extend_from_slice(&cuantas.to_le_bytes());
    cuerpo.extend_from_slice(&largo_central.to_le_bytes());
    cuerpo.extend_from_slice(&inicio.to_le_bytes());
    cuerpo.extend_from_slice(&0_u16.to_le_bytes());
    cuerpo
}

fn corpus(dir: &Path) -> PathBuf {
    let mut entradas: Vec<(&str, Vec<u8>)> = vec![
        ("mimetype", b"application/epub+zip".to_vec()),
        (
            "META-INF/container.xml",
            b"<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".to_vec(),
        ),
    ];
    let mut manifiesto = String::new();
    let mut lomo = String::new();
    let mut nav = String::new();
    let rutas: Vec<String> = CAPITULOS
        .iter()
        .map(|(h, _)| format!("OEBPS/{h}"))
        .collect();
    for (i, (href, cuerpo)) in CAPITULOS.iter().enumerate() {
        manifiesto.push_str(&format!(
            "<item id=\"c{i}\" href=\"{href}\" media-type=\"application/xhtml+xml\"/>"
        ));
        lomo.push_str(&format!("<itemref idref=\"c{i}\"/>"));
        nav.push_str(&format!("<li><a href=\"{href}\">Parte {}</a></li>", i + 1));
        entradas.push((
            rutas[i].as_str(),
            format!(
                "<?xml version=\"1.0\" encoding=\"utf-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>{href}</title></head><body>{cuerpo}</body></html>"
            )
            .into_bytes(),
        ));
    }
    entradas.push((
        "OEBPS/nav.xhtml",
        format!("<?xml version=\"1.0\" encoding=\"utf-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>Índice</title></head><body><nav epub:type=\"toc\"><ol>{nav}</ol></nav></body></html>").into_bytes(),
    ));
    entradas.push((
        "OEBPS/content.opf",
        format!("<?xml version=\"1.0\" encoding=\"utf-8\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"id\">conformidad</dc:identifier><dc:title>Corpus de conformidad</dc:title><dc:language>es</dc:language></metadata><manifest><item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>{manifiesto}</manifest><spine>{lomo}</spine></package>").into_bytes(),
    ));
    let ruta = dir.join("conformidad.epub");
    std::fs::File::create(&ruta)
        .and_then(|mut f| f.write_all(&zip(&entradas)))
        .expect("corpus");
    ruta
}

fn huella(texto: &str) -> String {
    use sha2::{Digest, Sha256};
    format!("{:x}", Sha256::digest(texto.as_bytes()))
}

#[test]
fn el_motor_responde_lo_grabado_en_el_corpus_de_conformidad() {
    let dir = std::env::temp_dir().join(format!("nb-conformidad-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("carpeta");
    let doc = EpubDocument::open(&corpus(&dir)).expect("abrir");

    let mut salida = serde_json::Map::new();
    salida.insert("lomo".into(), json!(doc.spine()));
    salida.insert(
        "indice".into(),
        serde_json::to_value(doc.navigation().expect("índice")).expect("json"),
    );

    let mut posiciones = Vec::new();
    for href in doc.spine() {
        for offset in [0_u32, 10, 40, 75] {
            let r = doc.locator_at(&NativePosition::Fragment {
                href: href.to_owned(),
                offset,
            });
            posiciones.push(match r {
                Ok(l) => {
                    let vuelta = doc.resolve(&l).expect("resolver");
                    json!({"href": href, "offset": offset, "locator": l, "resolucion": vuelta})
                }
                Err(e) => json!({"href": href, "offset": offset, "error": e.code()}),
            });
        }
    }
    salida.insert("posiciones".into(), Value::Array(posiciones));

    let mut citas = Vec::new();
    for cita in [
        "Nadie recordaba quién plantó",
        "Dos: ñandú, pingüino.",
        "Cuando llovía, los vecinos",
        "no existe en el libro",
    ] {
        citas.push(match doc.locator_for_quote(cita, Some(0.9)) {
            Ok(l) => json!({"cita": cita, "locator": l}),
            Err(e) => json!({"cita": cita, "error": e.code()}),
        });
    }
    salida.insert("citas".into(), Value::Array(citas));

    let fragmentos: Vec<Value> = doc
        .text_chunks(60)
        .expect("fragmentos")
        .into_iter()
        .map(|(l, t)| json!({"locator": l, "texto": t}))
        .collect();
    salida.insert("fragmentos".into(), Value::Array(fragmentos));

    let mut marcado = serde_json::Map::new();
    for href in doc.spine() {
        let pintado = doc
            .render(&NativePosition::Fragment {
                href: href.to_owned(),
                offset: 0,
            })
            .expect("pintar");
        marcado.insert(
            href.to_owned(),
            json!(huella(&serde_json::to_string(&pintado).expect("json"))),
        );
    }
    salida.insert("marcado".into(), Value::Object(marcado));
    let _ = std::fs::remove_dir_all(&dir);

    let texto = serde_json::to_string_pretty(&Value::Object(salida)).expect("json") + "\n";
    // Se regraba solo en NB Books, que es donde vive el motor. El teléfono lee
    // el grabado junto a este archivo, sea cual sea el crate que lo compile.
    if std::env::var_os("NB_GRABAR").is_some() {
        let grabado = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/conformidad.json");
        std::fs::write(&grabado, &texto).expect("grabar");
        return;
    }
    assert_eq!(
        texto,
        include_str!("conformidad.json"),
        "el motor ya no señala lo mismo que el corpus de conformidad"
    );
}
