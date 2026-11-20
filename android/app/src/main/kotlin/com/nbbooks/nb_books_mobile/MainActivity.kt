package com.nbbooks.nb_books_mobile

import android.os.Build
import android.os.Bundle
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import android.webkit.WebView
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * La actividad de Flutter más lo que Android tiene que hacer por su cuenta:
 *  - instalar la versión nueva que el lado Dart ya descargó y comprobó
 *    (canal `com.nbbooks/updater`);
 *  - pasar las teclas de volumen a Dart mientras Leer en el PC está abierto
 *    (canal `com.nbbooks/teclas`), para pasar página sin mirar la pantalla;
 *  - que el proceso que pinta el lector no se quede congelado (ver
 *    [mantenerLectores]).
 * Aquí no se abre ninguna conexión.
 */
class MainActivity : FlutterActivity() {

    private var updater: AppUpdater? = null
    private var teclas: MethodChannel? = null
    private var lector: MethodChannel? = null

    // Solo mientras la pantalla de control lo pide: el resto del tiempo el
    // volumen hace lo de siempre.
    private var capturarVolumen = false

    private val alCambiarLaVista = ViewTreeObserver.OnGlobalLayoutListener {
        mantenerLectores(window.decorView)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.decorView.viewTreeObserver.addOnGlobalLayoutListener(alCambiarLaVista)
    }

    /**
     * El WebView del lector nace antes de estar a la vista, y mientras no se ve
     * Android rebaja su proceso de pintado a "en caché". Algunos fabricantes
     * congelan esos procesos y no los despiertan al aparecer la vista: la página
     * se quedaba en blanco hasta cerrar la app. Con la prioridad fija, el
     * proceso sigue la importancia de la app y no la de la vista. Dart no carga
     * la página hasta que llega `vista` por `com.nbbooks/lector`: así el proceso
     * nace ya con esta prioridad y no hay un momento en que se pueda congelar.
     */
    private fun mantenerLectores(v: View) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (v is WebView) {
            if (v.getTag(R.id.prioridad_fijada) == null) {
                v.setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_IMPORTANT, false)
                v.setTag(R.id.prioridad_fijada, true)
                lector?.invokeMethod("vista", null)
            }
            return
        }
        if (v is ViewGroup) {
            for (i in 0 until v.childCount) mantenerLectores(v.getChildAt(i))
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val u = AppUpdater(this)
        updater = u
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.nbbooks/updater")
            .setMethodCallHandler(u)
        val t = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.nbbooks/teclas")
        t.setMethodCallHandler { call, result ->
            when (call.method) {
                "capturarVolumen" -> {
                    capturarVolumen = call.arguments as? Boolean ?: false
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        teclas = t
        lector = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.nbbooks/lector")
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (capturarVolumen &&
            (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)
        ) {
            teclas?.invokeMethod("volumen", if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) 1 else -1)
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        // Sin esto, soltar la tecla mostraría el control de volumen del sistema.
        if (capturarVolumen &&
            (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)
        ) {
            return true
        }
        return super.onKeyUp(keyCode, event)
    }

    override fun onDestroy() {
        window.decorView.viewTreeObserver.removeOnGlobalLayoutListener(alCambiarLaVista)
        updater?.dispose()
        updater = null
        teclas = null
        lector = null
        super.onDestroy()
    }
}
