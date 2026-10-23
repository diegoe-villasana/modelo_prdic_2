function y=olympus_four_rack_step(u)
% Four independent thermal networks; a single measured CFD supply is shared.
assert(isfield(u,'RackLoads') && numel(u.RackLoads)==4,'Four rack loads required.');
assert(isfield(u,'MeasuredCRACFlow_m3_s'),'Four-rack mode requires measured CFD flow.');
for n=1:4
    r=u.RackLoads(n);
    if ~isfield(r,'OtherIT_W_per_server') || isempty(r.OtherIT_W_per_server)
        u.RackLoads(n).OtherIT_W_per_server=0;r=u.RackLoads(n);
    end
    assert(all(isfinite([r.CPU1_W r.CPU2_W r.ServerFan_pct])) && ...
        all([r.CPU1_W r.CPU2_W]>=0) && all([r.CPU1_W r.CPU2_W]<=205) && ...
        r.ServerFan_pct>=0 && r.ServerFan_pct<=100 && ...
        isscalar(r.OtherIT_W_per_server) && isfinite(r.OtherIT_W_per_server) && ...
        r.OtherIT_W_per_server>=0,'Invalid rack command.');
end
for n=1:4
    p=u;p.RackId=n;p.MeasuredCRACFlow_m3_s=u.MeasuredCRACFlow_m3_s/4;
    p.CPU1_W_per_server=u.RackLoads(n).CPU1_W;p.CPU2_W_per_server=u.RackLoads(n).CPU2_W;
    p.OtherIT_W_per_server=u.RackLoads(n).OtherIT_W_per_server;
    p.ServerFanPWM_cmd_pct=u.RackLoads(n).ServerFan_pct;
    r=olympus_live_step(p);r.RackId=n;
    racks(n)=r; %#ok<AGROW>
end
y=racks(1);y.Racks=racks;y.RackCount=4;
y.CRAC_flow_m3_s=u.MeasuredCRACFlow_m3_s;
y.Rack_demand_flow_m3_s=sum([racks.Rack_demand_flow_m3_s]);
weights=[racks.Rack_demand_flow_m3_s];if sum(weights)==0,weights=ones(1,4);end;weights=weights/sum(weights);
y.Rack_inlet_C=sum(weights.*[racks.Rack_inlet_C]);y.Rack_outlet_C=sum(weights.*[racks.Rack_outlet_C]);
y.Recirculation_fraction=sum(weights.*[racks.Recirculation_fraction]);
y.CPU1_die_est_C=max([racks.CPU1_die_est_C]);y.CPU2_die_est_C=max([racks.CPU2_die_est_C]);
y.CPU1_heatsink_C=max([racks.CPU1_heatsink_C]);y.CPU2_heatsink_C=max([racks.CPU2_heatsink_C]);
for key={'Heat_input_J','Stored_energy_change_J','Heat_rejected_J','Energy_balance_residual_J','CPU_input_W','OtherIT_input_W','IT_input_W'}
    name=key{1};y.(name)=sum([racks.(name)]);
end
y.DataValid=all([racks.DataValid]);y.ThermalAlarm=any([racks.ThermalAlarm]);
y.AirDistributionModel='Equal allocation of measured floor supply to four independent rack thermal networks; room distribution not solved';
assert(abs(sum([racks.CRAC_flow_m3_s])-y.CRAC_flow_m3_s)<1e-10,'Supply allocation does not conserve flow');
end
