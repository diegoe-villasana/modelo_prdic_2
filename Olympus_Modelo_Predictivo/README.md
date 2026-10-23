# Olympus — Modelo predictivo y planta térmica

Paquete técnico para revisión y comparación. Documentación en español; código original del proyecto conservado sin cambios. Fecha de preparación: 22 de octubre de 2026.

## Qué modelo se utiliza

La reproducción operativa del centro de datos utiliza `simulation/generate_operational_timeseries.py`: una planta térmica simplificada con cuatro racks y dos unidades HVAC, una activa y otra de reserva. La estrategia anticipatoria combina realimentación de temperatura con una previsión de carga programada a 900 segundos. No es una red neuronal entrenada ni un controlador MPC con optimización. Los incrementos de carga no programados no se incluyen en la previsión.

El modelo MATLAB en `matlab/ProjectOlympus` es la planta térmica de la ruta alternativa en vivo y de los estudios de escalones. Incluye transporte de aire identificado mediante CFD y nodos térmicos provisionales. No debe confundirse con la planta operativa Python: sus dominios, capacidades y ecuaciones son diferentes. Esta entrega permite estudiar ambos; no incluye el entorno completo Emulate3D ni el caso ejecutable OpenFOAM.

## Ejecución independiente en Windows o Ubuntu

Requiere Python 3.11 o posterior. Desde la carpeta extraída:

```sh
python -m venv .venv
# Windows: .venv\Scripts\activate
# Ubuntu: source .venv/bin/activate
python -m pip install -r requirements.txt
python comparar_modelos.py
```

La comparación ejecuta ambas políticas durante 86 400 segundos, con paso de un segundo, la misma carga, clima y fallos. Escribe `resultados/comparacion_1s.csv` y `resultados/metricas.json`. `referencia/` contiene la ejecución verificada de esta entrega. Cada fila permite comparar temperatura máxima de entrada, potencia IT, previsión, consigna y ventilación; las temperaturas máximas incluyen el desplazamiento de sensor superior de 0.32 °C utilizado por el generador original.

Para generar todas las señales, alarmas y etiquetas futuras del proyecto:

```sh
python simulation/generate_operational_timeseries.py
python simulation/audit_operational.py
```

Los CSV completos se guardan en `data/operational_timeseries`. La matriz de variables original está incluida como dependencia. La auditoría escribe sus métricas en `reports/`. Los nombres históricos de archivo de esa auditoría se conservan; no representan la fecha de una nueva validación física.

## Ecuaciones y parámetros operativos

`clip(x,a,b)` limita x al intervalo [a,b]. El tiempo de integración es 1 s.

- Carga programada: 31 + 27·B(h) + 3·sin(2π(h−5)/24) kW, donde B(h) es el producto de dos transiciones logísticas definido en `scenario_loads`. La carga real añade ráfagas y se limita a 16–80 kW; cuatro pesos variables distribuyen la carga.
- Previsión: carga programada en t+900 s. Temperatura exterior: 29 + 6·sin(2π(h−9)/24) °C, retenida durante cada hora; es sintética.
- Error e = temperatura de pasillo frío − 22 °C.
- Política base: consigna de suministro = clip(22−0.30e,20.5,22.5); ventilación = clip(62+2e,58,96) %.
- Estrategia anticipatoria: R = clip(35−0.035·max(previsión−50,0)−0.015·max(exterior−32,0),33.5,35). Consigna = clip(consigna base−0.45·(35−R),19.5,22.5); ventilación = clip(ventilación base+0.52·(previsión−35),58,96) %.
- Dinámica del ventilador: v[k]=v[k−1]+(orden−v[k−1])/8. El arranque de reserva puede imponer 88 % durante 180 s.
- Caudal nominal por HVAC: 10 400 CFM, aproximadamente 4.908 m³/s; potencia sensible de referencia: 87 kW. No son especificaciones confirmadas del equipo instalado.
- Caudal por rack proporcional a su carga. Incremento de temperatura objetivo = potencia/(ρ·cp·caudal); respuesta de salida de rack con constante de 65 s.
- Con ventilación: ΔT del pasillo por segundo = (T suministro−T pasillo)/32 + 0.025·P IT·1000/C. Sin ventilación: ΔT = P IT·1000/C. C=1.2×10⁶ J/K; ρ·cp=1.204×1004.4 J/(m³·K).
- Ruido de sensor reproducible con semilla 20260929. Las posiciones de sensor, inventario térmico y humedad son supuestos.

Consultar el código para saturaciones, capacidad térmica disponible, filtro, UPS y alarmas. El parámetro R es una consigna auxiliar, no una predicción de temperatura validada.

## MATLAB

Abrir `matlab/ProjectOlympus` como directorio de trabajo y ejecutar:

```matlab
test_live_step
test_four_racks
test_v9_model
results = run_rockwell_step_study();
results = run_week_scenario(20260929);
```

`olympus_live_step` integra los nodos térmicos; `olympus_four_rack_step` gestiona cuatro racks; `server_cfd_coefficients` interpola el barrido de ventilador; `simulate_olympus_twin` aplica perfiles temporales. Los CSV y JSON en `data` son entradas necesarias. PWM se expresa en porcentaje, no en Hz. El servidor TCP es opcional y su ruta CFD necesita servicios externos que no forman parte de este ZIP. Las pruebas MATLAB no equivalen a comprobar una conexión en vivo a Ubuntu o Emulate3D.

## Comparación con otro modelo

Usar idénticos tiempos, cargas reales, clima, estado HVAC y condiciones iniciales. No usar las etiquetas futuras de `forecast_targets_1min.csv` como entradas disponibles en tiempo real. Comparar máximos, segundos sobre 27 °C, integral sobre ese umbral y error de previsión de carga. El umbral de 27 °C es un criterio de escenario. Una reducción de temperatura no demuestra ahorro eléctrico ni precisión frente a un centro de datos real.

Los valores de `referencia/metricas.json` son resultados sintéticos reproducidos desde este código. Las resistencias y capacidades térmicas MATLAB requieren calibración; el CFD de un componente no valida la sala completa. Una comparación con mediciones reales debe añadir calibración y evaluación independiente.

## Archivos y trazabilidad

`INTEGRIDAD.json` contiene hashes SHA-256 de los archivos entregados. Los fuentes Python y MATLAB y sus datos de entrada se copiaron sin alterar las ecuaciones del proyecto. `comparar_modelos.py` es una utilidad de revisión que llama directamente al núcleo original. La entrega es independiente y no modifica el proyecto operativo.
