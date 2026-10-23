clear olympus_live_step
u=struct('dt_s',1,'Reset',true,'InputSequence',1,'CPU1_W_per_server',155,'CPU2_W_per_server',145,...
 'ServerFanPWM_cmd_pct',72,'CRAC_PWM_cmd_pct',72,'CRAC_capacity_fraction',1,'CRAC_supply_temp_C',22,...
 'MeasuredCRACFlow_m3_s',.74,'MeasuredSupplyTemp_C',22);
for n=1:4,u.RackLoads(n)=struct('CPU1_W',80+25*n,'CPU2_W',70+25*n,'ServerFan_pct',72);end
for step=1:15
 u.Reset=step==1;u.InputSequence=step;y=olympus_four_rack_step(u);
 assert(abs(sum([y.Racks.CRAC_flow_m3_s])-.74)<1e-10);
 assert(abs(y.Energy_balance_residual_J)<1e-5);
 assert(all(diff([y.Racks.CPU1_die_est_C])>0));
 assert(all([y.Racks.time_s]==step));
end
disp('PASS four independent racks, conserved flow/energy, ordered load response and synchronized clocks');
clear olympus_live_step
u.Reset=true;u.InputSequence=1;
for n=1:4,u.RackLoads(n).OtherIT_W_per_server=0;end
baseline=olympus_four_rack_step(u);
clear olympus_live_step
for n=1:4,u.RackLoads(n).OtherIT_W_per_server=150;end
withOtherIT=olympus_four_rack_step(u);
assert(abs(withOtherIT.OtherIT_input_W-4*20*150)<1e-9);
assert(abs(withOtherIT.IT_input_W-withOtherIT.CPU_input_W-withOtherIT.OtherIT_input_W)<1e-9);
assert(abs(withOtherIT.Heat_input_J-withOtherIT.IT_input_W*u.dt_s)<1e-9);
assert(withOtherIT.Rack_outlet_C>baseline.Rack_outlet_C);
assert(abs(withOtherIT.Energy_balance_residual_J)<1e-5);
disp('PASS separately metered non-CPU IT heat and total energy balance');
clear olympus_live_step
single=rmfield(u,'RackLoads');single.Reset=true;
olympus_live_step(single);single.Reset=false;olympus_live_step(single);
u.Reset=false;y=olympus_four_rack_step(u);
assert(all([y.Racks.time_s]==1),'Single-rack experiment contaminated room clocks');
singleResult=olympus_live_step(single);
assert(singleResult.time_s==3,'Room experiment contaminated single-rack clock');
disp('PASS single-rack and room histories are isolated');
