# Verificación de la entrega — 22 de octubre de 2026

La comparación Python se ejecutó desde la carpeta de entrega durante 86 400 pasos por política. Se comprobaron cargas, clima y disponibilidad HVAC idénticos entre políticas y temperaturas finitas.

| Indicador | Realimentación | Anticipación |
|---|---:|---:|
| Máximo de entrada superior (°C) | 29.05381568 | 26.88306222 |
| Segundos sobre 27 °C | 164 | 0 |
| Integral sobre 27 °C (°C·s) | 231.35092320 | 0 |

MATLAB R2026a ejecutó satisfactoriamente `test_live_step`, `test_four_racks` y `test_v9_model` desde esta entrega: conservación térmica, régimen transitorio y estacionario, caudal cero, entradas inválidas, reparto de cuatro racks, calor no CPU, aislamiento de historiales e interpolación CFD.

La generación completa de todas las tablas operativas no se volvió a ejecutar para preparar este ZIP. Tampoco se ejecutó la cadena en vivo Emulate3D–MATLAB–Ubuntu. Estos resultados verifican ejecución y consistencia numérica del alcance indicado, no precisión de campo.

Los fuentes del proyecto y los datos MATLAB coinciden byte por byte con los originales al preparar esta entrega. Las salidas de referencia se generaron con el núcleo Python original. El contenido no incluye conversaciones, credenciales, rutas personales ni herramientas de generación de documentos.
