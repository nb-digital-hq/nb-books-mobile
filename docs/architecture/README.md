# Arquitectura

> **Estado:** Implementado.

| Documento | Qué cubre |
|---|---|
| [Constitución](constitution.md) | Las reglas que ningún cambio puede romper |
| [Visión general](system-overview.md) | Capas, módulos y flujo de datos |
| [Contrato con el PC](pc-contract.md) | Protocolo `1` de NB Books visto desde el teléfono |
| [Motor de lectura](reading-engine.md) | El crate de NB Books, el puente con Rust, el Locator y el corpus de conformidad |
| [Lector](reader.md) | Superficie de lectura, paginación, selección, anotaciones y voz |
| [Almacenamiento](storage.md) | Base de datos local, archivos y preferencias |
| [Internacionalización](i18n.md) | Idiomas de la interfaz y cómo se traduce |
| [Política de dependencias](dependency-policy.md) | Qué puede entrar en la app y con qué licencia |
| [Glosario](glossary.md) | Términos del proyecto |
| [Clave de publicación](api/clave-de-publicacion.pem) | Clave pública Ed25519 que verifica `SHA256SUMS.sig` |
