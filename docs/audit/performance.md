# Rendimiento

> **Estado:** Aplicable.

| Experiencia | Presupuesto | Cómo se consigue |
|---|---|---|
| Abrir un libro descargado | Menos de un segundo hasta la primera página en un teléfono de gama media | El motor abre el archivo una vez y entrega solo el recurso visible |
| Pasar página | Inmediato | Paginación por columnas CSS dentro de la vista web, sin volver al motor |
| Biblioteca con miles de libros | Sin esperas al desplazar | Orden y filtros en SQL; "Todo el PC" se pide paginado |
| Sincronizar | Sin bloquear la interfaz | Páginas de 500 cambios en transacciones; subida en tandas de 300 |
| Descargar | Reanudable | `Range` sobre el archivo parcial |

Se mide en el dispositivo de referencia con la build de publicación. La muestra del corpus real se ejecuta en local
con `NB_BOOKS_CORPUS` y nunca se copia al repositorio.
