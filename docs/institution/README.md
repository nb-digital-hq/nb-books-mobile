# NB Books Mobile para instituciones

> **Estado:** Aplicable. **Audiencia:** dirección, áreas de tecnología, jurídicas y de cumplimiento.

NB Books Mobile es una aplicación para personas: el acompañante en el teléfono de NB Books, que funciona entre el
teléfono y el PC de quien la usa, por su red local.

## Lo que la aplicación es

* **Completa y gratuita.** Ninguna función se reserva a una edición de pago.
* **Local.** Sin cuentas, sin servidores de NB Digital y sin telemetría ([privacidad](../audit/privacy.md)).
* **Abierta.** Apache License 2.0, con todo lo que se distribuye dentro de la app también abierto
  ([licencias](../legal/licensing.md)).

## Dos modelos sobre la misma base

* **Las aplicaciones para personas son de código abierto.** NB Books Mobile es una de ellas.
* **Los módulos y servicios de gobernanza para instituciones son de pago**, con una licencia comercial institucional
  por suscripción, y no forman parte de este repositorio.
* **La frontera es técnica.** NB Books Mobile no depende de ningún componente comercial, no habla con ningún
  servidor institucional y no envía a nadie la biblioteca, las anotaciones ni la actividad de la persona.

## Despliegue en dispositivos gestionados

* **Android:** los APK firmados de cada publicación se pueden distribuir con la consola de gestión de dispositivos
  de la institución. La huella del certificado de firma está en [cadena de suministro](../audit/supply-chain.md).
* **iOS:** el `.ipa` se publica sin firma de Apple y sin haberse probado en un dispositivo real; una institución
  que lo despliegue lo firma con su propio perfil.
* La app solo necesita la red local hacia el PC; no requiere salida a internet.

## Datos personales

La app no trata datos personales en servidores: todo queda en el teléfono y en el PC de la persona
([protección de datos](../legal/data-protection.md)).
