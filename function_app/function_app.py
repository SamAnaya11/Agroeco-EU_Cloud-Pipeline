"""
function_app.py
---------------
Azure Function (Python, modelo de programación v2) con dos funciones que
ejecutan el mismo pipeline (src/pipeline.py):

    pipeline_mensual -> se ejecuta sola el día 1 de cada mes (timer trigger)
    pipeline_manual  -> se ejecuta al llamar a una URL (HTTP trigger), para
                        probar sin esperar un mes

Al desplegar, el script copia src/ y sql/ junto a este archivo, por eso
"from src.pipeline import ..." funciona en Azure.
"""

import json
import logging
import os

import azure.functions as func

from src.pipeline import ejecutar_pipeline

app = func.FunctionApp()

# Las librerías de Azure (Blob Storage, azure-identity) escriben cada petición
# HTTP en el log. Solo se guardan sus avisos y errores: así los logs del
# pipeline se leen mejor y se gasta menos cuota de Log Analytics.
logging.getLogger("azure.core.pipeline.policies.http_logging_policy").setLevel(logging.WARNING)
logging.getLogger("azure.identity").setLevel(logging.WARNING)

# Formato NCRONTAB (6 campos): {segundo} {minuto} {hora} {día} {mes} {día de la semana}
# "0 0 6 1 * *" = el día 1 de cada mes a las 06:00 UTC (07:00/08:00 en España)
HORARIO_MENSUAL = "0 0 6 1 * *"


@app.function_name(name="pipeline_mensual")
@app.timer_trigger(schedule=HORARIO_MENSUAL, arg_name="temporizador",
                   run_on_startup=False, use_monitor=True)
def pipeline_mensual(temporizador: func.TimerRequest) -> None:
    if temporizador.past_due:
        logging.warning("La ejecución llega con retraso respecto a la hora programada")
    resumen = ejecutar_pipeline()
    logging.info(f"Resumen: {resumen}")


@app.function_name(name="pipeline_manual")
@app.route(route="ejecutar", methods=["POST"], auth_level=func.AuthLevel.FUNCTION)
def pipeline_manual(req: func.HttpRequest) -> func.HttpResponse:
    """
    Ejecución manual. Necesita la clave de la función (auth_level=FUNCTION),
    así que nadie puede lanzarla sin ella.
    """
    # Interruptor para PROBAR LA ALERTA (ver docs/alertas.md): con la variable
    # PRUEBA_ALERTA=1 en la configuración de la Function App, falla a propósito.
    # Solo afecta a la ejecución manual, nunca al temporizador.
    if os.environ.get("PRUEBA_ALERTA") == "1":
        raise RuntimeError("Fallo provocado a propósito para probar la alerta (PRUEBA_ALERTA=1)")

    try:
        resumen = ejecutar_pipeline()
    except Exception:
        # El detalle completo queda en Application Insights. Se vuelve a lanzar el
        # error para que Azure marque la ejecución como FALLIDA (si se devolviera
        # un 500 "controlado", la alerta de fallos no lo vería). El cliente recibe
        # un 500 sin detalles.
        logging.exception("El pipeline ha fallado")
        raise

    return func.HttpResponse(json.dumps(resumen, ensure_ascii=False), status_code=200,
                             mimetype="application/json")
