function test_v9_model()
% CFD flow fidelity, thermal energy conservation and cross-CPU coupling.
p40=server_cfd_coefficients(40);
p60=server_cfd_coefficients(60);
p100=server_cfd_coefficients(100);
assert(p40.CalibrationDomain && p60.CalibrationDomain && p100.CalibrationDomain);
assert(p40.TotalFlow_m3s<p60.TotalFlow_m3s && p60.TotalFlow_m3s<p100.TotalFlow_m3s);
assert(~server_cfd_coefficients(20).CalibrationDomain);
clear olympus_live_step
u=struct('RackId',1,'dt_s',2,'Reset',true,'InputSequence',1,...
    'CPU1_W_per_server',205,'CPU2_W_per_server',205,...
    'ServerFanPWM_cmd_pct',100,'CRAC_PWM_cmd_pct',100,...
    'CRAC_capacity_fraction',1,'CRAC_supply_temp_C',20,...
    'MeasuredCRACFlow_m3_s',2);
for k=1:800
    u.Reset=(k==1);u.InputSequence=k;
    y=olympus_live_step(u);
    assert(abs(y.Energy_balance_residual_J)<1e-6);
end
assert(abs(y.Rack_demand_flow_m3_s-20*p100.TotalFlow_m3s)<1e-10);
assert(y.WithinCFDFlowDomain);
assert(abs(y.CPU1_die_est_C-(y.CPU1_heatsink_C+205*.08))<.02);
assert(y.Remote_heatsink_C<min([y.CPU1_heatsink_C y.CPU2_heatsink_C]));
steady=steady_sinks(p100,[205 205],y.Rack_outlet_C);
assert(max(abs([y.CPU1_heatsink_C y.CPU2_heatsink_C y.Remote_heatsink_C]-steady))<.05);
u.Reset=true;u.CPU2_W_per_server=0;u.InputSequence=801;
for k=801:1600
    u.Reset=(k==801);u.InputSequence=k;y=olympus_live_step(u);
end
assert(y.CPU1_heatsink_C>y.CPU2_heatsink_C);
assert(y.CPU2_heatsink_C>y.Rack_outlet_C);
assert(abs(y.Energy_balance_residual_J)<1e-6);
fprintf('PASS V9 flow interpolation, thermal conservation, steady network and asymmetric load coupling.\n');
end

function x=steady_sinks(p,power,air)
g=p.LocalConductance_W_K;gr=p.RemoteConductance_W_K;gp=1/p.HeatPipeResistance_K_W;
M=[g(1)+gp 0 -gp;0 g(2)+gp -gp;-gp -gp 2*gp+gr];
b=[power(1)+g(1)*air;power(2)+g(2)*air;gr*air];
x=(M\b).';
end
