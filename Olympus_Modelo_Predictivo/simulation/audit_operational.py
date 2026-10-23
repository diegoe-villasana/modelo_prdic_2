"""Independent delivery checks and full-resolution metrics; no field validation."""
import hashlib
import json
from pathlib import Path
import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'data/operational_timeseries'

def main():
    manifest = json.loads((DATA/'manifest.json').read_text())
    for name, expected in manifest['sha256'].items():
        assert hashlib.sha256((DATA/name).read_bytes()).hexdigest() == expected, name
    ups = pd.read_csv(DATA/'ups_1s.csv')
    rack = pd.read_csv(DATA/'racks_1s.csv')
    hvac = pd.read_csv(DATA/'hvac_1s.csv')
    outlets = pd.read_csv(DATA/'outlets_1s.csv')
    battery = ups.UPS_On_Battery == 1
    assert battery.sum() == 300
    assert (ups.loc[battery,'UPS_Input_kW'] == 0).all()
    assert np.allclose(ups.UPS_Output_kW, rack.Total_IT_kW, atol=1e-5)
    residual = (ups.UPS_Input_kW + ups.UPS_Battery_Discharge_kW -
                ups.UPS_Output_kW - ups.UPS_Battery_Charge_kW - ups.UPS_Loss_kW)
    assert residual.abs().max() < 3e-5
    stored = ups.UPS_Battery_SOC_pct.diff().iloc[1:].to_numpy()*100*36
    expected = (ups.UPS_Battery_Charge_kW-ups.UPS_Battery_Discharge_kW).iloc[:-1].to_numpy()
    # Five-decimal CSV SOC rounding produces <=0.036 kW differencing error.
    assert np.max(np.abs(stored-expected)) < .037
    supply = hvac.HVAC1_Airflow_m3s + hvac.HVAC2_Airflow_m3s
    assert np.allclose(supply, outlets.filter(regex='Airflow_m3s$').sum(axis=1), atol=3e-5)
    assert np.allclose(rack.Total_IT_kW, rack.filter(regex='RACK_Carga_kW$').sum(axis=1), atol=3e-5)
    for name, spec in manifest['files'].items():
        frame = pd.read_csv(DATA/name)
        assert len(frame) == spec['rows'], name
        assert frame.TimestampUTC.is_unique and frame.TimestampUTC.is_monotonic_increasing, name
        if len(frame)>1:
            assert np.allclose(np.diff(frame.Elapsed_s), np.diff(frame.Elapsed_s)[0]), name
    ff = rack[[f'RACK{i}_Inlet_Top_C' for i in range(1,5)]].max(axis=1)
    baseline = rack.Baseline_Max_Rack_Inlet_C
    metrics = {'status':'PASS', 'scope':'Synthetic data consistency, not physical validation',
               'ups_balance_max_kW':float(residual.abs().max()),
               'ups_soc_balance_max_kW':float(np.max(np.abs(stored-expected))),
               'min_ups_soc_pct':float(ups.UPS_Battery_SOC_pct.min()),
               'peak_it_kW':float(rack.Total_IT_kW.max()),
               'policies':{}}
    for name, series in [('feedback',baseline),('feedforward',ff)]:
        metrics['policies'][name]={'peak_C':float(series.max()),
            'peak_utc':rack.TimestampUTC.iloc[series.idxmax()],
            'seconds_above_27C':int((series>27).sum()),
            'degree_seconds_above_27C':float(np.maximum(series-27,0).sum()),
            'minute_sample_peak_C':float(series.iloc[::60].max())}
    (ROOT/'reports/audit_metrics_20261016.json').write_text(json.dumps(metrics,indent=2))
    print(json.dumps(metrics,indent=2))

if __name__=='__main__': main()
