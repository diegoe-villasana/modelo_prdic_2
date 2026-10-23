from pathlib import Path
import json
import numpy as np
import pandas as pd
from simulation.generate_operational_timeseries import simulated_day

def main():
    out = Path(__file__).resolve().parent / "resultados"
    out.mkdir(exist_ok=True)
    states = {name: simulated_day(86400, mode) for name, mode in
              [("feedback", "indoor_feedback"), ("anticipatorio", "anticipatory")]}
    a, b = states.values()
    for key in ["rack_load", "outside", "lead"]:
        assert np.array_equal(a[key], b[key]), key
    data = {"Elapsed_s": a["t"], "IT_kW": a["total_load"],
            "Prevision_IT_15min_kW": a["forecast_load"], "Exterior_C": a["outside"]}
    metrics = {"scope": "Simulacion sintetica; no validacion de campo", "duration_s": 86400,
               "step_s": 1, "policies": {}}
    for name, state in states.items():
        peak = state["rack_inlet"].max(axis=1) + .32
        assert np.isfinite(peak).all()
        data[name+"_EntradaMax_C"] = peak
        data[name+"_Suministro_SP_C"] = state["supply_sp"]
        data[name+"_Ventilacion_pct"] = state["fan_request"]
        metrics["policies"][name] = {"peak_C": float(peak.max()),
            "seconds_above_27C": int((peak > 27).sum()),
            "degree_seconds_above_27C": float(np.maximum(peak-27, 0).sum())}
    pd.DataFrame(data).to_csv(out/"comparacion_1s.csv", index=False, float_format="%.8f")
    (out/"metricas.json").write_text(json.dumps(metrics, indent=2), encoding="utf-8")
    print(json.dumps(metrics, indent=2))

if __name__ == "__main__":
    main()
