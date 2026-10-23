function last = test_live_step()
% Conservation, equilibrium, zero-flow behavior, invalid-input rejection.
u=struct('dt_s',.05,'Reset',true,'InputSequence',1,...
    'CPU1_W_per_server',205,'CPU2_W_per_server',190,...
    'ServerFanPWM_cmd_pct',100,'CRAC_PWM_cmd_pct',100,...
    'CRAC_capacity_fraction',1,'CRAC_supply_temp_C',22);
first=olympus_live_step(u);
assert(first.Rack_outlet_C-22<.001,...
    'Exhaust heat must pass through CPU and heatsink storage first.');
check_balance(first);
assert(first.CRAC_flow_m3_s>1,...
    'The tracer travel delay must not be applied to the airflow command.');
u.Reset=false; u.dt_s=2;
for k=2:601
    u.InputSequence=k; last=olympus_live_step(u); check_balance(last);
    assert(last.OutputSequence==k && last.DataValid);
end
qFresh=min(last.CRAC_flow_m3_s,last.Rack_demand_flow_m3_s);
expected=22+20*(205+190)/(1.204*1004.4*qFresh);
assert(abs(last.Rack_outlet_C-expected)<.002,'Steady heat balance failed.');
coeff=server_cfd_coefficients(100);
g=coeff.LocalConductance_W_K;gr=coeff.RemoteConductance_W_K;
gp=1/coeff.HeatPipeResistance_K_W;
M=[g(1)+gp 0 -gp;0 g(2)+gp -gp;-gp -gp 2*gp+gr];
b=[205+g(1)*expected;190+g(2)*expected;gr*expected];
steady=M\b;
assert(abs(last.CPU1_die_est_C-(steady(1)+205*.08))<.02,...
    'CPU equilibrium failed.');

% A supply reduction must change flow on this step, independently of tracer.
u.CRAC_capacity_fraction=.5; u.InputSequence=602;
reduced=olympus_live_step(u); check_balance(reduced);
assert(abs(reduced.CRAC_flow_m3_s-first.CRAC_flow_m3_s/2)<1e-12);
assert(reduced.Recirculation_fraction>.49 && reduced.Rack_inlet_C>22);

% With no air transport, all input energy remains in the thermal inventory.
u.Reset=true; u.dt_s=10; u.ServerFanPWM_cmd_pct=0; u.CRAC_PWM_cmd_pct=0;
last=olympus_live_step(u); check_balance(last);
assert(last.DataValid && abs(last.Heat_rejected_J)<1e-8);
assert(abs(last.Stored_energy_change_J-last.Heat_input_J)<1e-5);
assert(last.Rack_outlet_C<max(last.CPU1_die_est_C,last.CPU2_die_est_C));
assert(last.ThermalAlarm,'Powered CPUs with stopped server fans must alarm.');

% Actual floor CFD measurements override the default flow gain and supply.
u.Reset=true; u.dt_s=1; u.ServerFanPWM_cmd_pct=100;
u.MeasuredCRACFlow_m3_s=.5; u.MeasuredSupplyTemp_C=18;
measured=olympus_live_step(u); check_balance(measured);
assert(measured.CRAC_flow_m3_s==.5 && measured.Rack_inlet_C<19);
assert(measured.Rack_outlet_C<19,'Measured supply temperature was ignored.');

% A rejected packet cannot silently produce plausible-looking valid data.
u.CPU1_W_per_server=NaN;
try
    olympus_live_step(u);
    error('Olympus:TestFailure','Invalid input was accepted.');
catch e
    assert(strcmp(e.identifier,'Olympus:InvalidInput'));
end
fprintf('PASS: transient storage, energy conservation, equilibrium, flow/tracer separation, zero flow, CFD overrides, invalid input.\n');
end

function check_balance(y)
assert(abs(y.Energy_balance_residual_J)<1e-7*max(1,abs(y.Heat_input_J)),...
    'Energy conservation failed.');
end
