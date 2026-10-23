"""Generate synthetic, timestamped Olympus inputs and measurements for PLC handoff.

This is an operational design scenario, not a live PLC/OPC connection or a
validated thermal CFD model. It preserves the source matrix's acquisition
cadences and adds the four-rack, two-HVAC, one-UPS, four-outlet configuration.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "sources" / "MatrizVariables.xlsx"
DEFAULT_OUT = ROOT / "data" / "operational_timeseries"
START = pd.Timestamp("2026-09-29T00:00:00Z")
RHO_CP = 1.204 * 1004.4  # J/(m3 K), consistent with the MATLAB room ROM
HVAC_RATED_KW = 87.0  # reference 60-Hz DA085 net sensible capacity
HVAC_RATED_FLOW_M3S = 10400 * 0.00047194745  # reference 10,400 CFM
UPS_RATED_KW = 100.0  # design assumption; not an installed-device rating
UPS_BATTERY_KWH = 100.0  # design assumption
ROOM_HEAT_CAPACITY_J_K = 1.2e6  # provisional thermal inventory
SEED = 20260929


def scenario_loads(seconds: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Four distinct continuous rack loads and a forecast without surprise jobs."""
    hours = seconds / 3600.0
    business = 1 / (1 + np.exp(-(hours - 7) * 1.8)) / (1 + np.exp((hours - 20) * 1.5))
    scheduled = 31 + 27 * business + 3.0 * np.sin(2 * np.pi * (hours - 5) / 24)
    burst = np.zeros_like(seconds, dtype=float)
    burst[(seconds >= 11 * 3600 + 45 * 60) & (seconds < 12 * 3600 + 30 * 60)] += 18
    burst[(seconds >= 13 * 3600 + 50 * 60) & (seconds < 14 * 3600 + 15 * 60)] += 18
    total = np.clip(scheduled + burst, 16, 80)
    weights = np.column_stack([
        .23 + .025 * np.sin(2 * np.pi * hours / 8),
        .25 + .015 * np.cos(2 * np.pi * hours / 5),
        .27 + .018 * np.sin(2 * np.pi * (hours - 1) / 6),
        .25 + .012 * np.cos(2 * np.pi * (hours + 1) / 7),
    ])
    weights /= weights.sum(axis=1)[:, None]
    return total[:, None] * weights, scheduled


def outdoor_temperature(seconds: np.ndarray) -> np.ndarray:
    hours = seconds / 3600
    return 29 + 6.0 * np.sin(2 * np.pi * (hours - 9) / 24)


def timestamp_index(period_s: float, duration_s: int) -> pd.DatetimeIndex:
    samples = round(duration_s / period_s)
    return pd.date_range(START, periods=samples, freq=pd.Timedelta(seconds=period_s))


def simulated_day(duration_s: int, control_mode: str = "anticipatory") -> dict[str, np.ndarray]:
    if control_mode not in ("anticipatory", "indoor_feedback"):
        raise ValueError(control_mode)
    t = np.arange(duration_s, dtype=np.int32)
    rack_load, scheduled_load = scenario_loads(t)
    _, scheduled_extended = scenario_loads(np.arange(duration_s + 901, dtype=np.int32))
    total_load = rack_load.sum(axis=1)
    # The emulated Optix weather input is an hourly held observation, not a live REST call.
    outside = outdoor_temperature((t // 3600) * 3600)
    forecast_load = scheduled_extended[t + 900]  # misses surprise jobs
    predicted_return_sp = np.clip(35 - .035 * np.maximum(forecast_load - 50, 0)
                                  - .015 * np.maximum(outside - 32, 0), 33.5, 35)
    supply_sp = np.zeros(duration_s)
    fan_request = np.zeros(duration_s)
    fault_start, standby_start, repair_end = 14 * 3600, 14 * 3600 + 45, 14 * 3600 + 20 * 60
    filter_start, filter_end = 16 * 3600, 17 * 3600
    on_battery = (t >= 18 * 3600) & (t < 18 * 3600 + 5 * 60)
    door_open = (t >= 10 * 3600) & (t < 10 * 3600 + 4 * 60)
    lead = np.where(t < fault_start, 1, np.where(t < standby_start, 0, 2))
    fault1 = (t >= fault_start) & (t < repair_end)
    filter2 = (t >= filter_start) & (t < filter_end)
    flow = np.zeros((duration_s, 2), dtype=float)
    speed = np.zeros((duration_s, 2), dtype=float)
    speed_command = np.zeros((duration_s, 2), dtype=float)
    hvac_cooling = np.zeros((duration_s, 2), dtype=float)
    hvac_return = np.zeros((duration_s, 2), dtype=float)
    hvac_supply = np.zeros((duration_s, 2), dtype=float)
    rack_inlet = np.zeros((duration_s, 4), dtype=float)
    rack_outlet = np.zeros((duration_s, 4), dtype=float)
    outlet_flow = np.zeros((duration_s, 4), dtype=float)
    return_air = np.zeros(duration_s)
    supply_air = np.zeros(duration_s)
    room_inlet = np.zeros(duration_s)
    room_inlet[0] = 22.0
    rack_outlet[0] = 34.0
    ups_soc = np.zeros(duration_s)
    ups_soc[0] = 100.0
    rng = np.random.default_rng(SEED)
    slow_sensor_noise = rng.normal(0, .015, duration_s // 30 + 2)
    for i in range(duration_s):
        # Both policies use the same indoor feedback and disturbances. Only the
        # advanced policy adds available load/weather context (feedforward).
        feedback_error = room_inlet[i] - 22.0
        supply_sp[i] = float(np.clip(22.0 - .30 * feedback_error, 20.5, 22.5))
        fan_request[i] = float(np.clip(62.0 + 2.0 * feedback_error, 58, 96))
        if control_mode == "anticipatory":
            supply_sp[i] = float(np.clip(supply_sp[i] - .45 * (35 - predicted_return_sp[i]), 19.5, 22.5))
            fan_request[i] = float(np.clip(fan_request[i] + .52 * (forecast_load[i] - 35), 58, 96))
        active = int(lead[i])
        if active:
            unit = active - 1
            command = max(fan_request[i], 88 if i >= standby_start and i < standby_start + 180 else 0)
            speed_command[i, unit] = command
            speed[i, unit] = speed[i - 1, unit] + (command - speed[i - 1, unit]) / 8 if i else command
            speed[i, unit] = float(np.clip(speed[i, unit], 0, 100))
            derate = .85 if unit == 1 and filter2[i] else 1.0
            flow[i, unit] = HVAC_RATED_FLOW_M3S * speed[i, unit] / 100 * derate
        q = flow[i].sum()
        if q > .05:
            allocation = rack_load[i] / total_load[i]
            outlet_flow[i] = q * allocation
        else:
            outlet_flow[i] = 0
        rack_inlet[i] = room_inlet[i] + np.array([-.12, .02, .10, .20])
        if i and q <= .05:
            # During a stopped-fan interval, heated rack mass accumulates energy;
            # a forced-convection delta-T formula would diverge as flow goes to 0.
            rack_outlet[i] = rack_outlet[i - 1] + rack_load[i] * 1000 / 250000
        elif i:
            rack_delta = (rack_load[i] * 1000) / (RHO_CP * np.maximum(outlet_flow[i], .20))
            target_out = rack_inlet[i] + rack_delta
            rack_outlet[i] = rack_outlet[i - 1] + (target_out - rack_outlet[i - 1]) / 65
        return_air[i] = np.sum(rack_outlet[i] * rack_load[i]) / total_load[i]
        hvac_return[i] = return_air[i] + np.array([.08, -.08])
        if q > .05:
            unit = active - 1
            capacity = HVAC_RATED_KW * (.90 if unit == 1 and filter2[i] else 1.0)
            capacity *= 1 - .006 * max(outside[i] - 35, 0)
            required_kw = max(0, RHO_CP * q * (return_air[i] - supply_sp[i]) / 1000)
            hvac_cooling[i, unit] = min(capacity, required_kw)
            supply_air[i] = return_air[i] - hvac_cooling[i, unit] * 1000 / (RHO_CP * q)
        else:
            supply_air[i] = room_inlet[i]
        hvac_supply[i] = np.where(flow[i] > .05, supply_air[i], hvac_return[i])
        if i + 1 < duration_s:
            if q > .05:
                leak_kw = .025 * total_load[i]
                d_room = (supply_air[i] - room_inlet[i]) / 32 + leak_kw * 1000 / ROOM_HEAT_CAPACITY_J_K
            else:
                d_room = total_load[i] * 1000 / ROOM_HEAT_CAPACITY_J_K
            room_inlet[i + 1] = room_inlet[i] + d_room
            if on_battery[i]:
                ups_soc[i + 1] = max(0, ups_soc[i] - total_load[i] / UPS_BATTERY_KWH / 36)
            else:
                ups_soc[i + 1] = min(100, ups_soc[i] + (100 - ups_soc[i]) / 900)
    # A small, slowly varying sensor error is shared by all acquisition polls.
    noise = np.interp(t, np.arange(len(slow_sensor_noise)) * 30, slow_sensor_noise)
    rack_inlet_measured = rack_inlet + noise[:, None]
    return dict(t=t, rack_load=rack_load, total_load=total_load,
                scheduled_load=scheduled_load, forecast_load=forecast_load,
                outside=outside, predicted_return_sp=predicted_return_sp,
                supply_sp=supply_sp, fan_request=fan_request, lead=lead,
                fault1=fault1, filter2=filter2, on_battery=on_battery,
                door_open=door_open, flow=flow, speed=speed,
                speed_command=speed_command,
                hvac_cooling=hvac_cooling, hvac_return=hvac_return,
                hvac_supply=hvac_supply, rack_inlet=rack_inlet_measured,
                rack_outlet=rack_outlet, outlet_flow=outlet_flow,
                return_air=return_air, supply_air=supply_air,
                room_inlet=room_inlet, ups_soc=ups_soc,
                control_mode=control_mode)


def write_csv(path: Path, data: dict[str, np.ndarray], period_s: float,
              duration_s: int) -> tuple[int, list[str]]:
    frame = pd.DataFrame(data)
    frame.insert(0, "TimestampUTC", timestamp_index(period_s, duration_s).strftime("%Y-%m-%dT%H:%M:%S.%fZ"))
    frame.insert(1, "Elapsed_s", np.arange(len(frame)) * period_s)
    frame.to_csv(path, index=False, float_format="%.5f")
    return len(frame), list(frame.columns)


def write_tables(s: dict[str, np.ndarray], baseline: dict[str, np.ndarray], out: Path) -> dict[str, dict]:
    duration = len(s["t"])
    result = {}
    idx500 = np.arange(duration * 2) // 2
    idx100 = np.arange(duration * 10) // 10
    hvac500 = {}
    for unit in range(2):
        label = f"HVAC{unit+1}_"
        active = s["lead"] == unit + 1
        fan_kw = 6.0 * np.power(s["speed"][:, unit] / 100, 3)
        run = active & (s["flow"][:, unit] > .05)
        ready = np.ones(duration, dtype=bool)
        if unit == 0:
            ready &= ~s["fault1"]
        vals = {
            "VFD_Speed_Ref": s["speed_command"][:, unit],
            "VFD_CMD_Start": active.astype(int),
            "VFD_CMD_Stop": (~active).astype(int),
            "VFD_CMD_Reset": ((s["t"] >= 14 * 3600 + 20 * 60) &
                              (s["t"] < 14 * 3600 + 20 * 60 + 2)).astype(int) if unit == 0 else np.zeros(duration),
            "VFD_Speed_Read": s["speed"][:, unit],
            "VFD_Power_kW": fan_kw,
            "VFD_Current_A": fan_kw * 1000 / (math.sqrt(3) * 480 * .92 * .95),
            "VFD_Volt": 480 + .8 * np.sin(s["t"] / 211) + unit * .3,
            "VFD_Status": run.astype(int),
            "VFD_Ready": ready.astype(int),
            "CRAC_Temp_Retorno": s["hvac_return"][:, unit],
            "CRAC_Temp_Sum": s["hvac_supply"][:, unit],
            "CRAC_Status": run.astype(int),
        }
        for tag, val in vals.items():
            hvac500[label + tag] = np.asarray(val)[idx500]
    for rack in range(4):
        hvac500[f"RACK{rack+1}_RACK_Puerta_Pasillo"] = np.where(rack == 0, ~s["door_open"], True)[idx500].astype(int)
    hvac500.update({
        "PIDE_SetPoint": np.full(duration * 2, 35.0),
        "PIDE_CV_Salida": s["fan_request"][idx500],
        "PIDE_Modo_Auto": np.ones(duration * 2, dtype=int),
        "PIDE_Ganancia_Kp": np.full(duration * 2, 1.0),
        "PIDE_Ganancia_Ki": np.full(duration * 2, .02),
        "PIDE_Ganancia_Kd": np.full(duration * 2, .1),
        "PIDE_FF_Constante": np.full(duration * 2, .3),
        "CRAC_Setpoint_Anticipativo": s["predicted_return_sp"][idx500],
        "HVAC_Active_Unit": s["lead"][idx500],
        "Forecast_IT_kW_15min": s["forecast_load"][idx500],
    })
    result["plc_500ms.csv"] = dict(zip(("rows", "columns"), write_csv(out / "plc_500ms.csv", hvac500, .5, duration)))
    security = security_scenario(duration)
    result["security_1s.csv"] = dict(zip(("rows", "columns"), write_csv(out / "security_1s.csv", security, 1, duration)))
    transition = np.r_[True, np.any(np.diff(np.column_stack(list(security.values())), axis=0) != 0, axis=1)]
    transitions = pd.DataFrame(security).loc[transition].copy()
    transitions.insert(0, "Elapsed_s", np.arange(duration)[transition])
    transitions.insert(0, "TimestampUTC", (START + pd.to_timedelta(transitions["Elapsed_s"], unit="s")).astype(str))
    transitions.to_csv(out / "security_transitions.csv", index=False)
    alarms = {}
    for unit in range(2):
        label = f"HVAC{unit+1}_"
        alarms[label + "VFD_Error"] = (s["fault1"] if unit == 0 else np.zeros(duration, dtype=bool))[idx100].astype(int)
        alarms[label + "CRAC_Alarma_Filtro"] = (s["filter2"] if unit == 1 else np.zeros(duration, dtype=bool))[idx100].astype(int)
        alarms[label + "CRAC_Alarma_Flujo"] = (s["fault1"] if unit == 0 else np.zeros(duration, dtype=bool))[idx100].astype(int)
    for rack in range(4):
        alarms[f"RACK{rack+1}_RACK_Alarma_Puerta"] = (s["door_open"] if rack == 0 else np.zeros(duration, dtype=bool))[idx100].astype(int)
        alarms[f"RACK{rack+1}_RACK_Alarma_Humo"] = (security["Room_Smoke_Test_Active"] if rack == 0 else np.zeros(duration, dtype=int))[idx100]
    result["alarms_100ms.csv"] = dict(zip(("rows", "columns"), write_csv(out / "alarms_100ms.csv", alarms, .1, duration)))
    rack_data = {"Total_IT_kW": s["total_load"], "Room_Cold_Aisle_C": s["room_inlet"],
                 "Room_Return_C": s["return_air"], "HVAC_Supply_C": s["supply_air"],
                 "Outdoor_C": s["outside"], "HVAC_Supply_Setpoint_C": s["supply_sp"],
                 "Baseline_Cold_Aisle_C": baseline["room_inlet"],
                 "Baseline_Max_Rack_Inlet_C": baseline["rack_inlet"].max(axis=1) + .32}
    outlet_data = {}
    for rack in range(4):
        p = f"RACK{rack+1}_"
        tin = s["rack_inlet"][:, rack]
        rack_data[p + "RACK_Carga_kW"] = s["rack_load"][:, rack]
        rack_data[p + "Inlet_Bottom_C"] = tin - .22
        rack_data[p + "Inlet_Middle_C"] = tin
        rack_data[p + "Inlet_Top_C"] = tin + .32
        rack_data[p + "Exhaust_C"] = s["rack_outlet"][:, rack]
        rack_data[p + "Inlet_RH_pct"] = np.clip(45 - .9 * (tin - 22), 25, 55)
        outlet_data[f"OUTLET{rack+1}_Airflow_m3s"] = s["outlet_flow"][:, rack]
        outlet_data[f"OUTLET{rack+1}_Supply_C"] = s["supply_air"]
        outlet_data[f"OUTLET{rack+1}_Damper_pct"] = np.where(s["flow"].sum(axis=1) > .05,
                                                             100 * s["outlet_flow"][:, rack] /
                                                             np.maximum(s["flow"].sum(axis=1), .01), 0)
    result["racks_1s.csv"] = dict(zip(("rows", "columns"), write_csv(out / "racks_1s.csv", rack_data, 1, duration)))
    result["outlets_1s.csv"] = dict(zip(("rows", "columns"), write_csv(out / "outlets_1s.csv", outlet_data, 1, duration)))
    # Input is grid power. Battery discharge retains the original ideal-converter
    # assumption; recharge uses 95% efficiency and the explicit SOC recurrence.
    charge = np.where(s["on_battery"], 0.,
                      (100 - s["ups_soc"]) / 900 * UPS_BATTERY_KWH * 36)
    discharge = np.where(s["on_battery"], s["total_load"], 0.)
    grid = np.where(s["on_battery"], 0., s["total_load"] / .95 + charge / .95)
    loss = grid + discharge - s["total_load"] - charge
    ups = {"UPS_Input_kW": grid,
           "UPS_Output_kW": s["total_load"],
           "UPS_Load_pct": 100 * s["total_load"] / UPS_RATED_KW,
           "UPS_Battery_SOC_pct": s["ups_soc"],
           "UPS_On_Battery": s["on_battery"].astype(int),
           "UPS_Mains_Available": (~s["on_battery"]).astype(int),
           "UPS_Alarm": (s["on_battery"] | (s["total_load"] > UPS_RATED_KW)).astype(int),
           "UPS_Battery_Charge_kW": charge,
           "UPS_Battery_Discharge_kW": discharge,
           "UPS_Loss_kW": loss}
    result["ups_1s.csv"] = dict(zip(("rows", "columns"), write_csv(out / "ups_1s.csv", ups, 1, duration)))
    hvac_detail = {}
    for unit in range(2):
        p = f"HVAC{unit+1}_"
        hvac_detail[p + "Airflow_m3s"] = s["flow"][:, unit]
        hvac_detail[p + "Sensible_Cooling_kW"] = s["hvac_cooling"][:, unit]
        hvac_detail[p + "Return_C"] = s["hvac_return"][:, unit]
        hvac_detail[p + "Supply_C"] = s["hvac_supply"][:, unit]
        hvac_detail[p + "Operating"] = (s["lead"] == unit + 1).astype(int)
    result["hvac_1s.csv"] = dict(zip(("rows", "columns"), write_csv(out / "hvac_1s.csv", hvac_detail, 1, duration)))
    hour_index = np.arange(0, duration, 3600)
    weather = {"Temp_Exterior_API": s["outside"][hour_index],
               "Weather_Source": np.full(len(hour_index), "SYNTHETIC_PROFILE")}
    result["weather_1h.csv"] = dict(zip(("rows", "columns"), write_csv(out / "weather_1h.csv", weather, 3600, duration)))
    minute_index = np.arange(0, duration, 60)
    maximum_inlet = np.max(s["rack_inlet"] + .32, axis=1)
    forecast = {"Current_Max_Rack_Inlet_C": maximum_inlet[minute_index],
                "Scheduled_Load_Forecast_15min_kW": s["forecast_load"][minute_index]}
    for horizon in (60, 300, 900):
        peak = np.array([np.max(maximum_inlet[i:i + horizon + 1]) if i + horizon < duration
                         else np.nan for i in minute_index])
        forecast[f"Actual_Future_Peak_{horizon}s_C"] = peak
        forecast[f"Future_Peak_Delta_{horizon}s_C"] = peak - maximum_inlet[minute_index]
        forecast[f"Exceeds_27C_Within_{horizon}s"] = np.where(np.isfinite(peak), (peak > 27).astype(float), np.nan)
        forecast[f"Exceeds_24C_Within_{horizon}s"] = np.where(np.isfinite(peak), (peak > 24).astype(float), np.nan)
    result["forecast_targets_1min.csv"] = dict(zip(("rows", "columns"), write_csv(out / "forecast_targets_1min.csv", forecast, 60, duration)))
    minute = np.arange(0, duration, 60)
    comparison = {
        "Total_IT_kW": s["total_load"][minute],
        "Scheduled_Load_Forecast_15min_kW": s["forecast_load"][minute],
        "Outdoor_C_Hourly_Held": s["outside"][minute],
        "Indoor_Feedback_Cold_Aisle_C": baseline["room_inlet"][minute],
        "Anticipatory_Cold_Aisle_C": s["room_inlet"][minute],
        "Indoor_Feedback_Max_Rack_Inlet_C": baseline["rack_inlet"].max(axis=1)[minute] + .32,
        "Anticipatory_Max_Rack_Inlet_C": s["rack_inlet"].max(axis=1)[minute] + .32,
        "Indoor_Feedback_Supply_Setpoint_C": baseline["supply_sp"][minute],
        "Anticipatory_Supply_Setpoint_C": s["supply_sp"][minute],
        "Indoor_Feedback_Fan_Request_pct": baseline["fan_request"][minute],
        "Anticipatory_Fan_Request_pct": s["fan_request"][minute],
    }
    result["control_comparison_1min.csv"] = dict(zip(("rows", "columns"), write_csv(out / "control_comparison_1min.csv", comparison, 60, duration)))
    return result


def catalog(out: Path, files: dict[str, dict]) -> int:
    source = pd.read_excel(SOURCE, sheet_name=0, dtype=str)
    source = source[source["Nombre de la Variable"].notna()]
    assert len(source) == 29, "The supplied source matrix no longer has 29 base signals."
    rows = []
    for _, row in source.iterrows():
        tag = row["Nombre de la Variable"].strip()
        if tag.startswith("VFD_") or tag.startswith("CRAC_") and tag != "CRAC_Setpoint_Anticipativo":
            count, prefix = 2, "HVAC"
        elif tag.startswith("RACK_"):
            count, prefix = 4, "RACK"
        else:
            count, prefix = 1, ""
        for index in range(1, count + 1):
            expanded = f"{prefix}{index}_{tag}" if prefix else tag
            found = [name for name, info in files.items() if expanded in info["columns"]]
            if len(found) != 1:
                raise AssertionError(f"Source signal {expanded} is missing or duplicated: {found}")
            rows.append({"BaseTag": tag, "ExpandedTag": expanded,
                         "DataType": row["Tipo de Dato"],
                         "MatrixFrequency": row.iloc[6],
                         "DirectionInMatrix": row["Clasificación"],
                         "DescriptionInMatrix": row.iloc[7],
                         "OutputFile": found[0], "Provenance": "SIMULATED; no physical PLC connection"})
    pd.DataFrame(rows).to_csv(out / "signal_catalog.csv", index=False)
    return len(rows)


def validate(out: Path, files: dict[str, dict], duration: int) -> None:
    assert all(info["rows"] == duration / {"plc_500ms.csv": .5, "alarms_100ms.csv": .1,
                  "weather_1h.csv": 3600, "forecast_targets_1min.csv": 60,
                  "control_comparison_1min.csv": 60}.get(name, 1)
               for name, info in files.items())
    load_cols = [f"RACK{i}_RACK_Carga_kW" for i in range(1, 5)]
    top_cols = [f"RACK{i}_Inlet_Top_C" for i in range(1, 5)]
    loads = pd.read_csv(out / "racks_1s.csv", usecols=["Total_IT_kW"] + load_cols + top_cols)
    assert np.allclose(loads["Total_IT_kW"], loads[load_cols].sum(axis=1), atol=1e-7)
    assert loads["Total_IT_kW"].between(0, 80).all()
    alarms = pd.read_csv(out / "alarms_100ms.csv", usecols=["HVAC1_VFD_Error", "HVAC2_VFD_Error"])
    assert alarms["HVAC1_VFD_Error"].sum() > 0 and alarms["HVAC2_VFD_Error"].sum() == 0
    detail = pd.read_csv(out / "hvac_1s.csv", usecols=["HVAC1_Operating", "HVAC2_Operating"])
    assert (detail.iloc[:, 0] + detail.iloc[:, 1]).max() == 1
    assert (detail.iloc[:, 0] + detail.iloc[:, 1]).min() == 0  # fault-to-standby gap
    assert detail["HVAC2_Operating"].sum() > 0
    hvac = pd.read_csv(out / "hvac_1s.csv", usecols=["HVAC1_Airflow_m3s", "HVAC2_Airflow_m3s",
                                                   "HVAC1_Sensible_Cooling_kW", "HVAC2_Sensible_Cooling_kW"])
    outlets = pd.read_csv(out / "outlets_1s.csv", usecols=[f"OUTLET{i}_Airflow_m3s" for i in range(1, 5)])
    assert np.allclose(outlets.sum(axis=1), hvac[["HVAC1_Airflow_m3s", "HVAC2_Airflow_m3s"]].sum(axis=1), atol=5e-5)
    assert hvac[["HVAC1_Sensible_Cooling_kW", "HVAC2_Sensible_Cooling_kW"]].to_numpy().max() <= HVAC_RATED_KW + 1e-6
    ups = pd.read_csv(out / "ups_1s.csv", usecols=["UPS_Battery_SOC_pct", "UPS_On_Battery", "UPS_Output_kW"])
    assert ups["UPS_Battery_SOC_pct"].between(0, 100).all()
    assert ups.loc[ups["UPS_On_Battery"] == 1, "UPS_Battery_SOC_pct"].iloc[-1] < 100
    assert np.allclose(ups["UPS_Output_kW"], loads["Total_IT_kW"], atol=1e-5)
    predictions = pd.read_csv(out / "forecast_targets_1min.csv", usecols=["Exceeds_24C_Within_900s"])
    assert predictions["Exceeds_24C_Within_900s"].sum() > 0
    assert loads[top_cols].to_numpy().max() < 27
    security = pd.read_csv(out / "security_1s.csv")
    for hour, prefix in [(15, "Room_Access"), (17, "Room_Smoke")]:
        start = hour * 3600
        assert security.loc[start, "Room_Annunciator_Active"] == 1
        assert security.loc[start+60, "Room_Annunciator_Active"] == 0
        assert security.loc[start+120, prefix+"_Alarm_Latched"] == 1  # premature reset rejected
        assert security.loc[start+180, prefix+"_Alarm_Latched"] == 1  # input clear alone is insufficient
        assert security.loc[start+240, prefix+"_Alarm_Latched"] == 0
    assert security.loc[9*3600+10, "Room_Door_Open"] == 1
    assert security.loc[9*3600+10, "Room_Access_Alarm_Latched"] == 0
    assert security.loc[12*3600, "Room_Access_Denied"] == 1
    assert security.loc[12*3600, "Room_Door_Open"] == 0
    for info in files.values():
        assert info["rows"] > 0


def security_scenario(duration: int) -> dict[str, np.ndarray]:
    """Demonstration inputs and alarm state; not a fire cause-and-effect design.

    All events are half-open UTC intervals. Acknowledge silences the simulated
    annunciator; reset clears a latch only after its initiating input clears.
    Detector tests do not represent combustion or alter the thermal plant.
    """
    t = np.arange(duration)
    def during(start, stop):
        return (t >= start) & (t < stop)
    granted = during(9*3600, 9*3600+120)
    opened = during(9*3600+10, 9*3600+90) | during(15*3600, 15*3600+180)
    denied = during(12*3600, 12*3600+60)
    forced = opened & ~granted
    smoke = during(17*3600, 17*3600+180)
    ack = (t == 15*3600+60) | (t == 17*3600+60)
    # Includes deliberately premature resets while the initiating input is active.
    reset = (t == 15*3600+120) | (t == 15*3600+240) | (t == 17*3600+120) | (t == 17*3600+240)
    access_latch = np.zeros(duration, dtype=bool)
    smoke_latch = np.zeros(duration, dtype=bool)
    acknowledged = np.zeros(duration, dtype=bool)
    a = f = acknowledged_state = False
    for i in range(duration):
        new_alarm = (forced[i] and not a) or (smoke[i] and not f)
        if new_alarm:
            acknowledged_state = False
        a = bool(forced[i] or (a and not reset[i]))
        f = bool(smoke[i] or (f and not reset[i]))
        if ack[i] and (a or f):
            acknowledged_state = True
        if not (a or f):
            acknowledged_state = False
        access_latch[i], smoke_latch[i], acknowledged[i] = a, f, acknowledged_state
    return {name: values.astype(int) for name, values in {
        "Room_Access_Granted": granted, "Room_Access_Denied": denied,
        "Room_Door_Open": opened, "Room_Door_Forced": forced,
        "Room_Access_Alarm_Latched": access_latch,
        "Room_Smoke_Test_Active": smoke, "Room_Smoke_Alarm_Latched": smoke_latch,
        "Room_Alarm_Ack_Request": ack, "Room_Alarm_Reset_Request": reset,
        "Room_Alarm_Acknowledged": acknowledged,
        "Room_Annunciator_Active": (access_latch | smoke_latch) & ~acknowledged,
    }.items()}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--hours", type=int, default=24, choices=[24])
    args = parser.parse_args()
    duration = args.hours * 3600
    args.output.mkdir(parents=True, exist_ok=True)
    state = simulated_day(duration)
    baseline = simulated_day(duration, "indoor_feedback")
    assert np.array_equal(state["rack_load"], baseline["rack_load"])
    assert np.array_equal(state["outside"], baseline["outside"])
    assert np.array_equal(state["lead"], baseline["lead"])
    files = write_tables(state, baseline, args.output)
    count = catalog(args.output, files)
    validate(args.output, files, duration)
    events = [
        ("09:00:00", "09:02:00", "ROOM_AUTHORIZED_ACCESS_DOOR_OPEN_09_00_10_TO_09_01_30"),
        ("10:00:00", "10:04:00", "RACK1_DOOR_OPEN"),
        ("11:45:00", "12:30:00", "UNSCHEDULED_COMPUTE_BURST"),
        ("13:50:00", "14:15:00", "UNSCHEDULED_COMPUTE_BURST"),
        ("12:00:00", "12:01:00", "ROOM_ACCESS_DENIED_DOOR_STAYS_CLOSED"),
        ("15:00:00", "15:04:00", "ROOM_FORCED_DOOR_ALARM_ACK_15_01_EARLY_RESET_15_02_CLEAR_15_03_RESET_15_04"),
        ("17:00:00", "17:04:00", "RACK1_SMOKE_TEST_ACK_17_01_EARLY_RESET_17_02_CLEAR_17_03_RESET_17_04"),
        ("14:00:00", "14:00:45", "HVAC1_VFD_FAULT_AND_FAILOVER_GAP"),
        ("14:00:45", "24:00:00", "HVAC2_STANDBY_TAKES_OVER"),
        ("16:00:00", "17:00:00", "HVAC2_FILTER_FOULING"),
        ("18:00:00", "18:05:00", "UPS_ON_BATTERY"),
    ]
    with (args.output / "scenario_events.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["StartUTC", "EndUTC", "Event", "Provenance"])
        writer.writerows([(str(START + pd.Timedelta(start)), str(START + pd.Timedelta(stop)), event, "SIMULATED")
                          for start, stop, event in sorted(events)])
    manifest = {
        "status": "SIMULATED_QA_PASS", "start_utc": str(START), "duration_s": duration,
        "source_matrix": str(SOURCE.relative_to(ROOT)), "source_base_tags": 29,
        "source_matrix_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        "generator_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "expanded_matrix_signals": count, "files": files,
        "reference_hvac": {"model_class": "Vertiv Liebert DSE DA085 reference, not installed equipment",
                           "net_sensible_capacity_kW_per_unit": HVAC_RATED_KW,
                           "nominal_airflow_m3_s_per_unit": HVAC_RATED_FLOW_M3S,
                           "source": "https://www.vertiv.com/en-us/products-catalog/thermal-management/room-cooling/da085-85kw/"},
        "assumptions": {"four_racks": True, "servers_per_rack": 20,
                        "hvac_units": 2, "normal_running_units": 1, "standby_units": 1,
                        "ups_count": 1, "ups_rating_kW": UPS_RATED_KW,
                        "ups_battery_kWh": UPS_BATTERY_KWH,
                        "ups_grid_and_charge_efficiency": 0.95,
                        "ups_battery_discharge_efficiency": 1.0,
                        "ups_charge_recovery_time_constant_s": 900,
                        "outlet_count": 4, "room_heat_capacity_J_per_K": ROOM_HEAT_CAPACITY_J_K,
                        "electrical_supply_V_LL": 480,
                        "no_live_plc_or_opc_or_weather_connection": True},
        "security_demo": "Authorized and denied access, forced-door latch, rack-1 detector test. Acknowledgment silences annunciator; reset requires cleared input. No suppression, evacuation, HVAC shutdown, hardware lock or certified fire response. One-second inputs held in 100-ms rack alarm rows. Exact transitions in security_transitions.csv.",
        "cadence_note": "100 ms alarms; 500 ms OPC-style tags; 1 s rack/UPS/outlet/HVAC plant; 1 min offline future labels; 1 h synthetic weather. Repeated values are normal when a source updates more slowly than polling.",
        "comparison": {"policies": ["indoor_feedback", "anticipatory"],
                       "shared_disturbances": ["IT load", "hourly held synthetic outdoor temperature", "HVAC failure", "filter fouling"],
                       "indoor_feedback": "22 C target, proportional supply setpoint and fan response to current cold aisle temperature",
                       "anticipatory": "same indoor feedback plus scheduled 15-minute IT load and current hourly outdoor temperature feedforward",
                       "max_rack_inlet_C": {"indoor_feedback": float(np.max(baseline["rack_inlet"] + .32)),
                                            "anticipatory": float(np.max(state["rack_inlet"] + .32))},
                       "minutes_above_24C": {"indoor_feedback": int(np.count_nonzero(baseline["rack_inlet"].max(axis=1)[::60] + .32 > 24)),
                                             "anticipatory": int(np.count_nonzero(state["rack_inlet"].max(axis=1)[::60] + .32 > 24))},
                       "not_a_validated_energy_saving_or_PID_D_comparison": True},
        "model_limit": "Operational HVAC sizing, room inventory, sensor locations, humidity and UPS parameters are scenario assumptions. The matched control comparison uses the same simplified two-HVAC plant, not calibrated field data. Feedforward uses current hourly synthetic weather, not an actual REST feed or weather forecast. Earlier single-CRAC CFD remains separate.",
    }
    manifest["sha256"] = {name: hashlib.sha256((args.output / name).read_bytes()).hexdigest()
                          for name in [*files, "signal_catalog.csv", "scenario_events.csv", "security_transitions.csv"]}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(json.dumps({"status": manifest["status"], "base_tags": 29,
                      "expanded_tags": count,
                      "rows_by_file": {name: info["rows"] for name, info in files.items()},
                      "max_rack_inlet_C": float(np.max(state["rack_inlet"])),
                      "max_IT_kW": float(np.max(state["total_load"]))}, indent=2))


if __name__ == "__main__":
    main()
