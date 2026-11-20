# Registro de decisiones de arquitectura

> **Estado:** Aplicable. Un ADR aceptado solo se cambia con otro ADR.

Cada decisión con impacto en la arquitectura, en la licencia o en lo que la app promete se registra aquí con su
contexto, las alternativas y sus consecuencias. La plantilla es [000-template.md](000-template.md).

| ADR | Decisión | Estado |
|---|---|---|
| [001](001-tech-stack.md) | Flutter, Drift y Riverpod, con el motor de lectura de NB Books en Rust | Aceptado |
| [002](002-data-ownership.md) | Cada dato tiene un dueño y viaja en un solo sentido | Aceptado |
| [003](003-licensing-model.md) | Apache 2.0 para la app; lo institucional, comercial y separado | Aceptado |
| [004](004-network-exit.md) | Una sola puerta de red; cada destino lo pide la persona (ampliado por ADR-012) | Aceptado |
| [005](005-qr-scanner.md) | Escáner QR con ZXing en lugar de ML Kit | Aceptado |
| [006](006-internationalization.md) | Interfaz en español, inglés y portugués con el español como texto fuente | Aceptado |
| [007](007-platforms-and-distribution.md) | Android verificado, iOS sin probar, distribución solo por GitHub | Aceptado |
| [008](008-shared-reading-engine.md) | El motor de lectura es el de NB Books | Aceptado |
| [009](009-two-libraries.md) | Dos bibliotecas, y la persona decide qué llega y qué se ve | Aceptado |
| [010](010-read-on-pc.md) | Leer en el PC | Aceptado |
| [011](011-pc-only-features.md) | Lo que se queda en el PC | Aceptado |
| [012](012-author-photos.md) | Fotos de autores desde Wikimedia, solo si la persona lo enciende | Aceptado |
