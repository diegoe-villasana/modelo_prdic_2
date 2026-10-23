function p = server_cfd_coefficients(pwm)
%SERVER_CFD_COEFFICIENTS V9 flow interpolation with explicit thermal assumptions.
% 40-100% is the CFD sweep domain. Below 40% the flow interpolation to zero
% is an engineering extrapolation; the CFD did not validate it.
persistent data
if isempty(data)
    file=fullfile(fileparts(mfilename('fullpath')),'data','server_v9_fan_sweep.csv');
    data=readtable(file);
    assert(all(diff(data.PWM_pct)>0) && data.PWM_pct(end)==100,...
        'Olympus:BadCalibration','Invalid V9 sweep table.');
end
assert(isnumeric(pwm) && isreal(pwm) && isscalar(pwm) && isfinite(pwm) && ...
    pwm>=0 && pwm<=100,'Olympus:InvalidInput','PWM must be in [0,100].');
keys={'TotalFlow_m3s','CPU1FinFlow_m3s','CPU2FinFlow_m3s','RemoteFlow_m3s'};
x=[0;data.PWM_pct];
for k=1:numel(keys)
    y=[0;data.(keys{k})];
    p.(keys{k})=interp1(x,y,pwm,'linear');
end
p.CalibrationDomain=(pwm>=40 && pwm<=100);
p.PWM_pct=pwm;
% Geometric/thermal assumptions, kept separate from CFD-measured flows:
% local fin resistances at 100% from the 24-fin geometry analysis;
% 0.05 K/W heat-pipe path and 0.035 K/W remote convection per server.
p.HeatPipeResistance_K_W=0.05;
p.CPUToSinkResistance_K_W=0.08;
if pwm==0
    p.LocalConductance_W_K=[0 0];
    p.RemoteConductance_W_K=0;
else
    base=data(data.PWM_pct==100,:);
    local0=[1.35 0.62];
    flows=[p.CPU1FinFlow_m3s p.CPU2FinFlow_m3s];
    flow0=[base.CPU1FinFlow_m3s base.CPU2FinFlow_m3s];
    localR=local0.*max(flows./flow0,1e-9).^(-0.38);
    remoteR=0.035*max(p.RemoteFlow_m3s/base.RemoteFlow_m3s,1e-9)^(-0.38);
    p.LocalConductance_W_K=1./localR;
    p.RemoteConductance_W_K=1/remoteR;
end
p.ThermalBasis='CAD fin correlation and assumed heat-pipe resistance; no solid-temperature calibration';
end
