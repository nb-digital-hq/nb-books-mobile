# Cadena de suministro

> **Estado:** Implementado.

## Dependencias

* Versiones fijadas en `pubspec.lock` y `native/Cargo.lock`, que se versionan; PDFium fijado por versión y huella en
  `tool/motor.dart`.
* El motor de lectura es una exportación sellada de NB Books, comprobada archivo a archivo por `tool/guardianes/motor.dart`.
* Licencias comprobadas en cada verificación por `tool/guardianes/licencias.dart`; avisos generados en
  `THIRD-PARTY-NOTICES.md` ([política](../architecture/dependency-policy.md)).
* Dependabot vigila `pub`, Cargo, Gradle y GitHub Actions **solo con alertas**: no abre pull requests
  (`open-pull-requests-limit: 0`). Las actualizaciones se hacen a mano y se verifican con la suite completa.

## Alertas

Una alerta nueva se resuelve actualizando la dependencia. Una alerta que no afecte a la app y no tenga arreglo se
descarta en GitHub con su motivo escrito y se anota aquí con la fecha.

| Fecha | Alerta | Motivo |
|---|---|---|
| — | Ninguna descartada | — |

## Firma de las publicaciones

* Los APK se firman con la clave de NB Books Mobile (RSA 2048). La huella SHA-256 del certificado es
  `73:F3:B2:66:F0:8C:76:4B:53:A8:D2:7A:E4:36:9B:45:9E:B4:6E:C1:F5:D0:A9:B8:19:DB:95:5C:08:15:70:22`.
* `SHA256SUMS` lista la huella de cada archivo de la publicación y `SHA256SUMS.sig` es su firma Ed25519 con la
  clave de publicación de NB Digital, cuya parte pública está en
  [`clave-de-publicacion.pem`](../architecture/api/clave-de-publicacion.pem).
* El `.ipa` de iOS sale de GitHub Actions sin firma de Apple y entra en la misma lista firmada.

Comprobación ([publicación](../developer/releases.md)):

```bash
openssl pkeyutl -verify -pubin -inkey clave-de-publicacion.pem -rawin -in SHA256SUMS -sigfile SHA256SUMS.sig
sha256sum --check --strict SHA256SUMS
```

## Lo que no entra en el repositorio

Claves privadas, almacenes de firma, `key.properties`, binarios compilados (incluidos el motor y PDFium) y
configuración de herramientas de agentes (`tool/guardianes/secretos.dart`).
