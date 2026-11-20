//! Dónde se corta el texto de un documento en fragmentos.
//!
//! Contrato: `docs/architecture/ai/embeddings.md`, sección 1.
//!
//! # Por qué importa dónde se corta
//!
//! Antes cada formato cortaba cuando llegaba al tamaño del fragmento,
//! retrocediendo hasta el último espacio. Para la búsqueda léxica bastaba: una
//! palabra está entera en algún fragmento y eso es lo que se busca. Para la
//! búsqueda por significado no: un fragmento que acaba a mitad de una frase y
//! empieza la siguiente con media idea es un vector que no representa ni una ni
//! otra, y el modelo solo ve lo que hay dentro del fragmento.
//!
//! Así que se corta, por este orden de preferencia, **en el final de un párrafo,
//! en el final de una frase o en un espacio**, siempre dentro de la segunda mitad
//! del tamaño máximo. Dentro de la segunda mitad y no en cualquier punto porque
//! un párrafo de una línea al principio del tramo produciría un fragmento
//! diminuto, y cada fragmento cuesta una fila.
//!
//! # Por qué sin solapamiento
//!
//! `embeddings.md` hablaba de fragmentos "con solapamiento", que es lo habitual
//! cuando se trocea solo para vectorizar. Aquí el fragmento es **el mismo** para
//! el índice léxico y para el vectorial —es lo que permite que la búsqueda
//! híbrida acote con uno y ordene con el otro sin traducir entre dos
//! troceados—, y en el léxico el solapamiento duplicaría cada coincidencia de la
//! zona compartida y haría crecer el índice. Cortar por párrafo consigue lo que el
//! solapamiento buscaba —que una idea no quede partida— sin ese precio.

use std::ops::Range;

/// Los tramos en que se parte un texto.
///
/// `fronteras` son los desplazamientos, en caracteres, donde **empieza** un
/// bloque: un párrafo, un elemento de lista, un encabezado. Tienen que estar
/// ordenados. Un formato que no los conoce pasa una lista vacía y se corta por
/// frase o por espacio.
///
/// Los tramos cubren el texto entero, sin huecos ni solapamiento, y ninguno pasa
/// de `maximo` caracteres. Los que solo tienen espacio en blanco se devuelven
/// igual: descartarlos es cosa de quien los guarda.
#[must_use]
pub fn segmentar(caracteres: &[char], fronteras: &[usize], maximo: usize) -> Vec<Range<usize>> {
    let maximo = maximo.max(1);
    let mut tramos = Vec::new();
    let mut inicio = 0;

    while inicio < caracteres.len() {
        let tope = (inicio + maximo).min(caracteres.len());
        let fin = if tope == caracteres.len() {
            tope
        } else {
            corte(caracteres, fronteras, inicio, tope, maximo)
        };
        tramos.push(inicio..fin);
        inicio = fin;
    }
    tramos
}

/// Dónde acaba el tramo que empieza en `inicio` y no puede pasar de `tope`.
fn corte(
    caracteres: &[char],
    fronteras: &[usize],
    inicio: usize,
    tope: usize,
    maximo: usize,
) -> usize {
    // Por debajo de la mitad no se busca un corte mejor: ver la cabecera.
    let suelo = inicio + maximo / 2;

    // El comienzo de un bloque, el último que cabe.
    let limite = fronteras.partition_point(|&f| f <= tope);
    if let Some(&frontera) = fronteras[..limite].last() {
        if frontera > suelo {
            return frontera;
        }
    }

    // El comienzo de una frase: tras un signo de final y un espacio.
    if let Some(p) = (suelo + 1..=tope)
        .rev()
        .find(|&p| empieza_frase(caracteres, p))
    {
        return p;
    }

    // Tras un espacio, que es lo que se hacía. Partir una palabra
    // la dejaría fuera del índice léxico en las dos mitades.
    if let Some(p) = (inicio + 1..=tope)
        .rev()
        .find(|&p| caracteres[p - 1].is_whitespace())
    {
        return p;
    }

    tope
}

/// Si en `p` empieza una frase: hay un espacio justo antes, y antes de él un
/// signo que cierra una frase, quizá seguido de unas comillas o un paréntesis.
fn empieza_frase(caracteres: &[char], p: usize) -> bool {
    if p < 2 || !caracteres[p - 1].is_whitespace() {
        return false;
    }
    let mut i = p - 2;
    while i > 0 && matches!(caracteres[i], '"' | '\'' | '»' | '”' | '’' | ')' | ']') {
        i -= 1;
    }
    matches!(caracteres[i], '.' | '?' | '!' | '…')
}

/// Los comienzos de bloque de un texto donde los bloques se separan por una línea
/// en blanco: dos saltos de línea seguidos, con espacio o sin él entre ellos.
///
/// Es lo que tienen el texto de una página de PDF y el de un formato de texto
/// corrido: un salto de línea suelto es una línea y no un párrafo, porque el PDF
/// parte las líneas donde las partió la maquetación.
#[must_use]
pub fn fronteras_por_linea_en_blanco(caracteres: &[char]) -> Vec<usize> {
    let mut fronteras = Vec::new();
    let mut saltos = 0;
    for (i, &c) in caracteres.iter().enumerate() {
        if c == '\n' {
            saltos += 1;
        } else if !c.is_whitespace() {
            if saltos >= 2 {
                fronteras.push(i);
            }
            saltos = 0;
        }
    }
    fronteras
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chars(texto: &str) -> Vec<char> {
        texto.chars().collect()
    }

    fn trozos(texto: &str, fronteras: &[usize], maximo: usize) -> Vec<String> {
        let c = chars(texto);
        segmentar(&c, fronteras, maximo)
            .into_iter()
            .map(|r| c[r].iter().collect())
            .collect()
    }

    /// Los tramos cubren el texto entero, sin huecos ni solapamiento, y ninguno
    /// pasa del máximo, con cualquier tamaño y cualquier texto. Es la propiedad
    /// que hace que cortar mejor no pueda perder texto del índice.
    #[test]
    fn los_tramos_cubren_todo_el_texto_sin_pasar_del_maximo() {
        let texto = "Primera frase. Segunda frase, más larga que la otra? Sí! «Cita.» Fin (del texto.) \
                     Palabrasinespaciosquenocabeenningúntramoporsermuylarga y otra cosa.\n\nNuevo párrafo.";
        let c = chars(texto);
        let fronteras = fronteras_por_linea_en_blanco(&c);
        for maximo in 1..=c.len() + 3 {
            let tramos = segmentar(&c, &fronteras, maximo);
            let mut esperado = 0;
            for tramo in &tramos {
                assert_eq!(
                    tramo.start, esperado,
                    "hueco o solapamiento con máximo {maximo}"
                );
                assert!(tramo.end > tramo.start);
                assert!(
                    tramo.len() <= maximo,
                    "un tramo de {} con máximo {maximo}",
                    tramo.len()
                );
                esperado = tramo.end;
            }
            assert_eq!(esperado, c.len());
        }
    }

    /// **El criterio en su forma más pequeña**: con un párrafo que acaba
    /// dentro de la segunda mitad, el corte cae ahí y no en el último espacio.
    #[test]
    fn se_corta_al_final_del_parrafo_antes_que_en_un_espacio() {
        let texto = "Uno dos tres cuatro. Cinco seis siete ocho nueve diez once doce";
        let parrafo = texto.find("Cinco").expect("párrafo");
        let t = trozos(texto, &[parrafo], 40);
        assert_eq!(t[0], "Uno dos tres cuatro. ");
    }

    /// Sin párrafo que sirva, al final de una frase, también tras unas comillas de
    /// cierre; y sin frase, en un espacio, que es lo de antes.
    #[test]
    fn sin_parrafo_se_corta_en_una_frase_y_sin_frase_en_un_espacio() {
        assert_eq!(
            trozos(
                "Una frase entera. Y otra que sigue sin punto final aquí",
                &[],
                30
            )[0],
            "Una frase entera. "
        );
        assert_eq!(
            trozos("Dijo: «Hasta mañana.» Y se fue caminando despacio", &[], 30)[0],
            "Dijo: «Hasta mañana.» "
        );
        assert_eq!(
            trozos("palabras sin ningún signo que cierre una frase", &[], 30)[0],
            "palabras sin ningún signo que "
        );
    }

    /// Un párrafo o una frase que acaban en la primera mitad **no** se usan: darían
    /// fragmentos diminutos, y cada fragmento es una fila.
    #[test]
    fn un_corte_en_la_primera_mitad_no_se_usa() {
        let texto = "Hola. Esto sigue siendo el mismo párrafo largo sin puntos";
        let c = chars(texto);
        let t = trozos(texto, &[6], 40);
        assert!(t[0].len() > 20, "se cortó en la primera mitad: {:?}", t[0]);
        assert!(c.len() > 40);
    }

    /// Una línea suelta no es un párrafo; una línea en blanco, sí.
    #[test]
    fn un_salto_de_linea_suelto_no_es_un_parrafo() {
        let c = chars("una línea\nsigue el párrafo\n\n  otro párrafo\n \nel tercero");
        let fronteras = fronteras_por_linea_en_blanco(&c);
        let empiezan: Vec<String> = fronteras
            .iter()
            .map(|&f| c[f..].iter().take(4).collect())
            .collect();
        assert_eq!(empiezan, vec!["otro", "el t"]);
    }
}
