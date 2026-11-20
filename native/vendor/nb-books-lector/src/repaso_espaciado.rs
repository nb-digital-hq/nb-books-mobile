//! Algoritmo determinista de repaso espaciado.
//!
//! Contrato: sección 2.2 de `docs/design/reading-experience/README.md`.
//!
//! # Principio: determinismo estricto
//!
//! El cálculo de intervalos, factores de facilidad y fechas de vencimiento es una
//! función pura sin efectos colaterales ni dependencias del reloj del sistema.
//! Recibe el estado actual y la calificación, y produce el siguiente estado.
//!
//! # Algoritmo: SM-2 adaptado con cota de facilidad
//!
//! - `Again` (olvidada): reinicia repeticiones a 0, intervalo a 1 día, y reduce
//!   la facilidad en 0.20 (hasta un mínimo de 1.3).
//! - `Hard` (difícil): incrementa repeticiones, amplía el intervalo de forma
//!   moderada (1 -> 3 -> `intervalo * 1.2`) y reduce la facilidad en 0.15 (mínimo 1.3).
//! - `Good` (recordada bien): progresión clásica (1 -> 6 -> `intervalo * facilidad`),
//!   facilidad constante.
//! - `Easy` (fácil): progresión rápida (4 -> `6 * facilidad` -> `intervalo * facilidad * 1.3`),
//!   aumenta la facilidad en 0.15 (tope 3.0).

use serde::{Deserialize, Serialize};
use ts_rs::TS;

use crate::error::{NbError, NbResult};

/// Calificación de recuerdo al repasar una tarjeta o pregunta.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export, export_to = "../../src/lib/bindings/", rename = "ReviewRating")]
pub enum CalificacionRepaso {
    /// No se recordó: reinicia el ciclo.
    Again,
    /// Se recordó con esfuerzo: incremento contenido.
    Hard,
    /// Se recordó bien: progresión estándar.
    Good,
    /// Se recordó con facilidad: progresión con bonificación.
    Easy,
}

/// Estado de programación de una tarjeta en el sistema de repaso espaciado.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EstadoRepaso {
    pub repetitions: u32,
    pub interval_days: u32,
    pub ease_factor: f64,
}

/// Facilidad mínima según el estándar SM-2 para evitar estancamientos ("ease hell").
pub const FACILIDAD_MINIMA: f64 = 1.3;
/// Facilidad inicial para tarjetas nuevas.
pub const FACILIDAD_INICIAL: f64 = 2.5;
/// Facilidad máxima admisible para acotar el crecimiento desmedido.
pub const FACILIDAD_MAXIMA: f64 = 3.0;

/// Calcula de forma estrictamente determinista el siguiente estado de repaso.
#[must_use]
pub fn calcular_repaso(actual: EstadoRepaso, calificacion: CalificacionRepaso) -> EstadoRepaso {
    let ease = actual.ease_factor.clamp(FACILIDAD_MINIMA, FACILIDAD_MAXIMA);

    match calificacion {
        CalificacionRepaso::Again => EstadoRepaso {
            repetitions: 0,
            interval_days: 1,
            ease_factor: (ease - 0.20).max(FACILIDAD_MINIMA),
        },
        CalificacionRepaso::Hard => {
            let next_rep = actual.repetitions + 1;
            let next_interval = match next_rep {
                1 => 1,
                2 => 3,
                _ => ((actual.interval_days as f64 * 1.2).round() as u32)
                    .max(actual.interval_days + 1),
            };
            EstadoRepaso {
                repetitions: next_rep,
                interval_days: next_interval,
                ease_factor: (ease - 0.15).max(FACILIDAD_MINIMA),
            }
        }
        CalificacionRepaso::Good => {
            let next_rep = actual.repetitions + 1;
            let next_interval = match next_rep {
                1 => 1,
                2 => 6,
                _ => ((actual.interval_days as f64 * ease).round() as u32)
                    .max(actual.interval_days + 1),
            };
            EstadoRepaso {
                repetitions: next_rep,
                interval_days: next_interval,
                ease_factor: ease,
            }
        }
        CalificacionRepaso::Easy => {
            let next_rep = actual.repetitions + 1;
            let next_interval = match next_rep {
                1 => 4,
                2 => ((6.0 * ease).round() as u32).max(7),
                _ => ((actual.interval_days as f64 * ease * 1.3).round() as u32)
                    .max(actual.interval_days + 2),
            };
            EstadoRepaso {
                repetitions: next_rep,
                interval_days: next_interval,
                ease_factor: (ease + 0.15).min(FACILIDAD_MAXIMA),
            }
        }
    }
}

/// Días civiles desde la época 1970-01-01 (algoritmo de Howard Hinnant).
fn dias_desde_civil(y: i32, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as u32;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era as i64 * 146097 + doe as i64 - 719468
}

/// Convierte días civiles desde la época a (año, mes, día) gregoriano.
fn civil_desde_dias(z: i64) -> (i32, u32, u32) {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = (z - era * 146097) as u32;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe as i32 + era as i32 * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

/// Suma un número de días a una fecha o marca de tiempo ISO 8601 (`YYYY-MM-DD...`).
///
/// Si la entrada contiene una hora (`T...`), se conserva íntegra al final.
///
/// # Errors
///
/// Devuelve [`NbError::Internal`] si la cadena no comienza con una fecha válida en formato `YYYY-MM-DD`.
pub fn sumar_dias(fecha_iso: &str, dias: u32) -> NbResult<String> {
    if fecha_iso.len() < 10 {
        return Err(NbError::Internal);
    }
    let fecha_parte = &fecha_iso[0..10];
    let resto_parte = &fecha_iso[10..];

    let mut partes = fecha_parte.split('-');
    let anio: i32 = partes
        .next()
        .and_then(|s| s.parse().ok())
        .ok_or(NbError::Internal)?;
    let mes: u32 = partes
        .next()
        .and_then(|s| s.parse().ok())
        .ok_or(NbError::Internal)?;
    let dia: u32 = partes
        .next()
        .and_then(|s| s.parse().ok())
        .ok_or(NbError::Internal)?;

    if !(1..=12).contains(&mes) || !(1..=31).contains(&dia) {
        return Err(NbError::Internal);
    }

    let dias_base = dias_desde_civil(anio, mes, dia);
    let dias_nuevos = dias_base + i64::from(dias);
    let (nuevo_anio, nuevo_mes, nuevo_dia) = civil_desde_dias(dias_nuevos);

    Ok(format!(
        "{nuevo_anio:04}-{nuevo_mes:02}-{nuevo_dia:02}{resto_parte}"
    ))
}

impl CalificacionRepaso {
    /// Forma con la que se guarda en el registro de repasos y viaja al teléfono.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Again => "again",
            Self::Hard => "hard",
            Self::Good => "good",
            Self::Easy => "easy",
        }
    }

    /// Lee la forma guardada.
    ///
    /// # Errors
    ///
    /// [`NbError::DocumentCorrupted`] si no es una de las cuatro.
    pub fn desde_str(texto: &str) -> NbResult<Self> {
        match texto {
            "again" => Ok(Self::Again),
            "hard" => Ok(Self::Hard),
            "good" => Ok(Self::Good),
            "easy" => Ok(Self::Easy),
            _ => Err(NbError::DocumentCorrupted),
        }
    }
}

/// Lo que se sabe de una tarjeta en un momento: su estado y sus fechas.
#[derive(Debug, Clone, PartialEq)]
pub struct Programacion {
    pub estado: EstadoRepaso,
    pub due_at: String,
    pub last_reviewed_at: Option<String>,
}

/// Aplica en orden los repasos de una tarjeta a su punto de partida.
///
/// # Por qué se reproduce y no se guarda el último estado
///
/// Porque la misma tarjeta se repasa en el PC y en el teléfono, a veces sin que
/// se vean. Si viajara el estado, uno de los dos repasos se perdería al
/// sincronizar; viajando los repasos, los dos dispositivos aplican la misma
/// lista en el mismo orden a la misma base y llegan al mismo resultado sin
/// elegir a nadie. El orden lo pone quien llama: por instante y, a igualdad,
/// por identificador, para que sea total.
///
/// # Errors
///
/// [`NbError::Internal`] si una fecha del registro no tiene forma ISO-8601.
pub fn reproducir(
    base: Programacion,
    repasos: &[(String, CalificacionRepaso)],
) -> NbResult<Programacion> {
    let mut actual = base;
    for (repasado_en, calificacion) in repasos {
        let estado = calcular_repaso(actual.estado, *calificacion);
        actual = Programacion {
            due_at: sumar_dias(repasado_en, estado.interval_days)?,
            last_reviewed_at: Some(repasado_en.clone()),
            estado,
        };
    }
    Ok(actual)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn calculo_es_estrictamente_determinista() {
        let inicial = EstadoRepaso {
            repetitions: 0,
            interval_days: 0,
            ease_factor: 2.5,
        };

        // Primera respuesta Good -> 1 día
        let paso1 = calcular_repaso(inicial, CalificacionRepaso::Good);
        assert_eq!(paso1.repetitions, 1);
        assert_eq!(paso1.interval_days, 1);
        assert!((paso1.ease_factor - 2.5).abs() < f64::EPSILON);

        // Segunda respuesta Good -> 6 días
        let paso2 = calcular_repaso(paso1, CalificacionRepaso::Good);
        assert_eq!(paso2.repetitions, 2);
        assert_eq!(paso2.interval_days, 6);

        // Tercera respuesta Good -> 6 * 2.5 = 15 días
        let paso3 = calcular_repaso(paso2, CalificacionRepaso::Good);
        assert_eq!(paso3.repetitions, 3);
        assert_eq!(paso3.interval_days, 15);

        // Cuarta respuesta Good -> 15 * 2.5 = 38 días (redondeado)
        let paso4 = calcular_repaso(paso3, CalificacionRepaso::Good);
        assert_eq!(paso4.repetitions, 4);
        assert_eq!(paso4.interval_days, 38);
    }

    #[test]
    fn fallo_reinicia_repeticiones_e_intervalo() {
        let consolidada = EstadoRepaso {
            repetitions: 5,
            interval_days: 90,
            ease_factor: 2.5,
        };

        let fallada = calcular_repaso(consolidada, CalificacionRepaso::Again);
        assert_eq!(fallada.repetitions, 0);
        assert_eq!(fallada.interval_days, 1);
        assert!((fallada.ease_factor - 2.3).abs() < 1e-6);

        // Múltiples fallos no bajan la facilidad por debajo de 1.3
        let mut actual = consolidada;
        for _ in 0..15 {
            actual = calcular_repaso(actual, CalificacionRepaso::Again);
        }
        assert_eq!(actual.repetitions, 0);
        assert_eq!(actual.interval_days, 1);
        assert!((actual.ease_factor - 1.3).abs() < 1e-6);
    }

    #[test]
    fn facil_acelera_intervalo_y_aumenta_facilidad() {
        let inicial = EstadoRepaso {
            repetitions: 0,
            interval_days: 0,
            ease_factor: 2.5,
        };

        let paso1 = calcular_repaso(inicial, CalificacionRepaso::Easy);
        assert_eq!(paso1.repetitions, 1);
        assert_eq!(paso1.interval_days, 4);
        assert!((paso1.ease_factor - 2.65).abs() < 1e-6);

        let paso2 = calcular_repaso(paso1, CalificacionRepaso::Easy);
        assert_eq!(paso2.repetitions, 2);
        // 6 * 2.65 = 15.9 -> 16
        assert_eq!(paso2.interval_days, 16);
        assert!((paso2.ease_factor - 2.80).abs() < 1e-6);
    }

    #[test]
    fn dificil_incrementa_moderadamente_y_reduce_facilidad() {
        let paso1 = EstadoRepaso {
            repetitions: 1,
            interval_days: 1,
            ease_factor: 2.5,
        };

        let paso2 = calcular_repaso(paso1, CalificacionRepaso::Hard);
        assert_eq!(paso2.repetitions, 2);
        assert_eq!(paso2.interval_days, 3);
        assert!((paso2.ease_factor - 2.35).abs() < 1e-6);

        let paso3 = calcular_repaso(paso2, CalificacionRepaso::Hard);
        assert_eq!(paso3.repetitions, 3);
        // 3 * 1.2 = 3.6 -> 4
        assert_eq!(paso3.interval_days, 4);
        assert!((paso3.ease_factor - 2.20).abs() < 1e-6);
    }

    #[test]
    fn suma_dias_es_exacta_y_maneja_bisiestos_y_cambios_de_ano() {
        // Mismo mes
        assert_eq!(
            sumar_dias("2026-10-16T12:00:00.000Z", 5).unwrap(),
            "2026-10-21T12:00:00.000Z"
        );
        // Cambio de mes en octubre (31 días)
        assert_eq!(
            sumar_dias("2026-10-25T08:30:00.000Z", 10).unwrap(),
            "2026-11-04T08:30:00.000Z"
        );
        // Cambio de año
        assert_eq!(
            sumar_dias("2026-12-30T00:00:00.000Z", 5).unwrap(),
            "2027-01-04T00:00:00.000Z"
        );
        // Año bisiesto 2028 (febrero tiene 29 días)
        assert_eq!(
            sumar_dias("2028-02-27T00:00:00.000Z", 2).unwrap(),
            "2028-02-29T00:00:00.000Z"
        );
        assert_eq!(
            sumar_dias("2028-02-27T00:00:00.000Z", 3).unwrap(),
            "2028-03-01T00:00:00.000Z"
        );
        // Fecha sin hora
        assert_eq!(sumar_dias("2026-06-15", 20).unwrap(), "2026-07-05");
    }

    #[test]
    fn reproducir_los_mismos_repasos_da_lo_mismo_en_cualquier_dispositivo() {
        let base = Programacion {
            estado: EstadoRepaso {
                repetitions: 0,
                interval_days: 0,
                ease_factor: FACILIDAD_INICIAL,
            },
            due_at: "2026-01-01T00:00:00.000Z".to_owned(),
            last_reviewed_at: None,
        };
        let repasos = vec![
            (
                "2026-01-01T10:00:00.000Z".to_owned(),
                CalificacionRepaso::Good,
            ),
            (
                "2026-01-02T10:00:00.000Z".to_owned(),
                CalificacionRepaso::Hard,
            ),
            (
                "2026-01-05T10:00:00.000Z".to_owned(),
                CalificacionRepaso::Easy,
            ),
        ];
        let a = reproducir(base.clone(), &repasos).expect("reproducir");
        let b = reproducir(base, &repasos).expect("reproducir");
        assert_eq!(a, b);
        assert_eq!(
            a.last_reviewed_at.as_deref(),
            Some("2026-01-05T10:00:00.000Z")
        );
        assert_eq!(a.estado.repetitions, 3);
    }

    #[test]
    fn la_calificacion_guardada_se_lee_igual_que_se_escribio() {
        for c in [
            CalificacionRepaso::Again,
            CalificacionRepaso::Hard,
            CalificacionRepaso::Good,
            CalificacionRepaso::Easy,
        ] {
            assert_eq!(CalificacionRepaso::desde_str(c.as_str()), Ok(c));
        }
        assert!(CalificacionRepaso::desde_str("otra").is_err());
    }
}
