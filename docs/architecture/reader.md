# Lector

> **Estado:** Implementado.

## Superficie

El lector pinta el marcado que devuelve el motor en una vista web local (`webview_flutter`). La página es HTML
generada por la app (`lector_html.dart`): su política de contenido solo admite datos incrustados, la navegación
fuera de la página se bloquea y el marcado ya llega saneado por el motor. Las imágenes del libro se incrustan como
datos.

* **Paginado:** columnas CSS del ancho exacto de la vista, así que pasar página desplaza un ancho y nunca arrastra
  media línea. Tocar los bordes o deslizar pasa página; el centro muestra los controles.
* **Continuo:** el capítulo se desplaza seguido.
* **Pie y barra de posición:** el pie enseña el título del capítulo (del índice del libro) y la página dentro del
  capítulo que informa la página web. El porcentaje es el del texto (`totalProgression` del Locator), el mismo que
  enseña la biblioteca. Al abrir, el motor da dónde empieza cada capítulo en esa escala, y la barra salta al capítulo
  que contiene el punto elegido y, dentro, a la parte proporcional.
* **Colores:** fondo, letra y tema se aplican a la página en cuanto cambian, con la hoja de ajustes abierta. Los
  colores que trae el propio libro no mandan sobre los de la lectura: un texto negro del libro sobre el fondo de
  noche no se leería.
* **Composición:** la vista web va a pantalla completa con una franja reservada abajo, y el pie se superpone en esa
  franja. Dentro de un `Column`, la vista web con composición híbrida quedaba tapada en las compilaciones de
  publicación aunque su contenido estuviera pintado.
* **Proceso de pintado (Android):** el WebView pinta en un proceso aparte que Android rebaja a "en caché"
  mientras la vista no se ve, y algunos fabricantes congelan esos procesos sin despertarlos después.
  `MainActivity` fija la prioridad del proceso en cuanto la vista existe (`setRendererPriorityPolicy`) y avisa por
  `com.nbbooks/lector`; solo entonces se carga la página. Si en diez segundos la página no responde, se rehace la
  vista una vez y, si tampoco, se dice qué hacer en lugar de dejar una hoja en blanco.
* **Ajustes del libro:** tamaño de letra, interlineado, márgenes, letra con remates, justificado y paginado.
* PDF y cómic se pintan como imágenes de página que produce el motor.

## Posición

Al cambiar de página, la vista web informa del primer bloque visible (sin contar los que envuelven a otros, como
un diario entero dentro de una cita, que estarían siempre a la vista) y el motor devuelve su Locator, que se guarda
como posición del dispositivo `telefono`. Al abrir, la app sitúa el libro en esa posición; si la vista aún no tiene
tamaño, el destino espera a tenerlo. Si el PC va más adelante, el menú ofrece "Ir a donde voy en el PC".

## Selección y anotaciones

Pulsar y mantener elige la palabra; arrastrar sin soltar extiende la selección, aunque cruce párrafos. Si la pulsación
larga del sistema se adelanta y se queda el toque, la selección que deja (y la que se ajusta con sus tiradores) se
sigue igual, y la barra para anotar aparece. La selección es propia de la página
y no usa el menú contextual del sistema, que en la vista web incrustada la cancelaba. Con texto elegido aparece la
barra con Nota, Resaltar, Subrayar y Copiar. Cada anotación guarda el Locator de la cita (`locator_for_quote`), y
tocar una marca la abre. Al pintarla, la cita se busca en el capítulo sin contar espacios (entre dos párrafos el
Locator lleva un espacio que el documento no tiene) y, si la frase se repite, gana la aparición precedida del
contexto `before` del Locator. Las anotaciones son inmutables: editar una nota es darla de baja y crear otra.

## Voz y avance automático

"Leer en voz alta" usa las voces del sistema (`flutter_tts`) con el texto que da el motor desde la posición actual. El avance
automático desplaza el texto a una velocidad fija mientras el lector está abierto.

## Sesiones

Abrir el lector empieza una sesión con el Locator inicial; cerrarlo la termina con el final y lanza una
sincronización. Las referencias a la base de datos y a la sincronización se toman al montar la pantalla, porque al
desmontarla ya no se puede leer de los proveedores.
